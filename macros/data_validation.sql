{#
    Returns a normal dbt ref() to a model while conditionally adding a
    dependency on that model''s validation-merge node.

    Warehouse models use this instead of ref() when consuming models that may
    have validations applied after their initial build.

    If data validation is enabled and at least one validator is registered for
    model_name, this macro adds an otherwise invisible dependency on the
    corresponding val_* model. This ensures dbt waits for validation results to
    be merged into the referenced model before a downstream model reads it.

    The val_* model is used only as a dependency barrier. It does not replace
    the requested relation in the generated SQL. The macro always returns the
    original model referenced by model_name.

    For example:

        validated_ref('stg_ef3__calendars')

    still produces a reference to stg_ef3__calendars, but when validators are
    configured it also establishes a dependency on val_ef3__calendars.

    If validation is disabled or no validators are registered for model_name,
    this behaves exactly like a normal ref().

    The SQL comment emitted when a validation dependency is added has no effect
    on dbt dependency resolution. It exists only to make the otherwise invisible
    dependency apparent when inspecting compiled SQL.
#}
{% macro validated_ref(model_name) -%}

    {%- set validation_config = var('edu:data_validation', {}) -%}
    {%- set validation_enabled = validation_config.get('enabled', false) -%}
    {%- set rules = validation_config.get('models', {}).get(model_name, []) -%}

    {%- if validation_enabled and rules | length > 0 -%}

        {# Derive the validation-merge node associated with this model. #}
        {%- set validation_model = 'val_' ~ (model_name | replace('stg_', '')) -%}

        {#
            Establish the validation dependency without emitting the val_*
            relation into the generated SQL.
        #}
        {%- do ref(validation_model) -%}

        {#
            Return the requested model normally. The comment makes the injected
            validation dependency visible when inspecting compiled SQL.
        #}
        {{- ref(model_name) }} /* validation: depends on {{ validation_model }} */

    {%- else -%}

        {# With no applicable validation, behave exactly like ref(). #}
        {{- ref(model_name) }}

    {%- endif -%}

{%- endmacro %}

{#
    Internal helper used by combine_validations().

    Returns a SQL expression containing the distinct validation findings from
    the supplied sources whose severities are configured for warehouse
    propagation.

    The configured edu:data_validation.severities mapping acts as the
    propagation allowlist. Findings with severities not present in that mapping
    are intentionally excluded.

    In normal mode, validations are combined across the supplied sources for
    the current input row.

    When aggregate=true, validations are additionally collected across every
    input row contributing to the current GROUP BY result before being
    flattened and deduplicated.

    If no severities are configured, a correctly typed empty validation array
    is returned.

    This macro returns only a SQL expression. It does not emit a column alias
    or leading comma and is intended to be consumed by combine_validations().
#}
{% macro _combined_validation_array(sources, aggregate=false) -%}

    {%- set validation_config = var('edu:data_validation', {}) -%}
    {%- set severities = validation_config.get('severities', {}) -%}

    array_distinct(
        flatten(
            {% if aggregate %}
                collect_list(
                    flatten(
                        array(
                            {% for source in sources %}

                                {% if severities | length > 0 %}
                                    filter(
                                        coalesce(
                                            {{ source }}.validations,
                                            cast(
                                                array() as {{ edu_edfi_source.validation_struct_type() }}
                                            )
                                        ),
                                        v -> v.severity in (
                                            {% for severity in severities.keys() %}
                                            '{{ severity }}'{% if not loop.last %},{% endif %}
                                            {% endfor %}
                                        )
                                    )
                                {% else %}
                                    cast(
                                        array() as {{ edu_edfi_source.validation_struct_type() }}
                                    )
                                {% endif %}{% if not loop.last %},{% endif %}

                            {% endfor %}
                        )
                    )
                )

            {% else %}

                array(
                    {% for source in sources %}

                        {% if severities | length > 0 %}
                            filter(
                                coalesce(
                                    {{ source }}.validations,
                                    cast(
                                        array() as {{ edu_edfi_source.validation_struct_type() }}
                                    )
                                ),
                                v -> v.severity in (
                                    {% for severity in severities.keys() %}
                                    '{{ severity }}'{% if not loop.last %},{% endif %}
                                    {% endfor %}
                                )
                            )
                        {% else %}
                            cast(
                                array() as {{ edu_edfi_source.validation_struct_type() }}
                            )
                        {% endif %}{% if not loop.last %},{% endif %}

                    {% endfor %}
                )

            {% endif %}
        )
    )

{%- endmacro %}


{#
    Combines validation results from one or more upstream models and appends
    them to a warehouse model.

    In normal mode, validations are combined across the supplied source
    relations for the current row.

    When aggregate=true, the input query is expected to contain a GROUP BY.
    Validations from every input row contributing to the resulting warehouse
    row are collected, flattened, and deduplicated. Validation columns therefore
    do not need to become part of the model''s grouping key.

    Only validations whose severity appears in edu:data_validation.severities
    are propagated into warehouse models. The same severity configuration is
    used to calculate validation_severity from the validations that survive
    filtering.

    validation_severity is calculated from the exact same filtered validation
    array that is propagated. A finding removed during propagation therefore
    cannot influence the resulting severity.

    If no validations survive filtering, validation_severity falls back to
    default_severity, which is normally null.

    The leading comma is intentional so this macro can be appended directly to
    an existing SELECT column list.
#}
{% macro combine_validations(sources, aggregate=false) -%}

    {%- set validation_config = var('edu:data_validation', {}) -%}
    {%- set severities = validation_config.get('severities', {}) -%}

    {%- if validation_config.get('enabled', false)
        and validation_config.get('propagate_validations', false) %}

        ,

        {# Build the array of validation findings eligible for propagation. #}
        {{ edu_wh._combined_validation_array(
            sources,
            aggregate=aggregate
        ) }} as validations,

        {#
            Determine the highest severity from the propagated validations.

            Each surviving finding is converted to its configured numeric rank.
            array_max() selects the highest rank, which is then mapped back to
            the corresponding severity name.
        #}
        coalesce(
            {% if severities | length > 0 %}

                case array_max(
                    transform(
                        {{ edu_wh._combined_validation_array(
                            sources,
                            aggregate=aggregate
                        ) }},
                        v -> case v.severity
                            {% for severity, rank in severities.items() %}
                            when '{{ severity }}' then {{ rank }}
                            {% endfor %}
                        end
                    )
                )
                    {% for severity, rank in severities.items() %}
                    when {{ rank }} then '{{ severity }}'
                    {% endfor %}
                end

            {% else %}

                null

            {% endif %},

            {{ validation_config.get('default_severity', 'null') }}
        ) as validation_severity

    {%- endif %}

{%- endmacro %}


{#
    Materializes warehouse-level validator results back into an existing
    warehouse model.

    Warehouse models may already contain validations inherited from their
    upstream staging or warehouse dependencies. Unlike the source-layer
    validation materialization, this materialization preserves those existing
    findings and appends the newly generated warehouse-level findings.

    Each configured validator produces one row per validation finding containing
    the target model''s key columns and a validation struct that follows the
    canonical validation contract.

    This materialization:
      - filters out findings whose severity is not configured;
      - aggregates new validation findings by the target model''s key;
      - appends those findings to the target row''s existing validations;
      - removes duplicate validation structs;
      - compares the existing and newly calculated validation severities; and
      - stores the highest configured severity on the target row.

    target_model identifies the warehouse model receiving the validation
    results.

    target_keys contains one or more columns that uniquely identify a row in
    target_model. These columns are used for both aggregation and the MERGE
    condition.

    edu:data_validation.severities serves as both the allowlist for findings stored
    on warehouse models and the numeric ranking used to calculate
    validation_severity. Findings whose severity is not configured are discarded
    before aggregation. If no severities are configured, no warehouse-level
    findings are merged.

    This materialization mutates target_model directly. The associated val_*
    dbt node acts as a dependency barrier and does not create its own relation.
#}
{% materialization edu_wh_validation_merge -%}

    {%- set validation_config = var('edu:data_validation', {}) -%}
    {%- set severities = validation_config.get('severities', {}) -%}

    {# Identify the warehouse relation and key columns receiving the findings. #}
    {%- set target_model = config.require('target_model') -%}
    {%- set target_keys = config.require('target_keys') -%}
    {%- set target_relation = ref(target_model) -%}

    {%- call statement('main') %}

        merge into {{ target_relation }} as target

        using (
            select
                {# Preserve the complete target key, including composite keys. #}
                {% for key in target_keys %}
                    {{ adapter.quote(key) }}{% if not loop.last %},{% endif %}
                {% endfor %},

                {#
                    Collect only findings whose severity is allowed by the
                    configured severities map.
                #}
                collect_list(validation) as validations,

                {#
                    Determine the highest configured severity among the
                    allowed findings for the target row.
                #}
                {% if severities | length > 0 %}
                    max_by(
                        validation.severity,
                        case validation.severity
                            {% for severity, rank in severities.items() %}
                                when '{{ severity }}' then {{ rank }}
                            {% endfor %}
                        end
                    )
                {% else %}
                    cast(null as string)
                {% endif %} as validation_severity

            from (
                {#
                    sql contains the UNION ALL of warehouse validator models
                    generated by validation_models_for().
                #}
                {{ sql }}
            ) as validation_rows

            {#
                Configured severities are the allowlist for warehouse
                validation storage. Findings with unconfigured severities
                are discarded before aggregation and cannot affect either
                validations or validation_severity.

                When no severities are configured, no findings are allowed.
            #}
            where
                {% if severities | length > 0 %}
                    validation.severity in (
                        {% for severity in severities.keys() %}
                            '{{ severity }}'
                            {% if not loop.last %},{% endif %}
                        {% endfor %}
                    )
                {% else %}
                    false
                {% endif %}

            group by
                {% for key in target_keys %}
                    {{ adapter.quote(key) }}{% if not loop.last %},{% endif %}
                {% endfor %}
        ) as source

        {# Match the aggregated findings to the exact warehouse row. #}
        on
        {% for key in target_keys %}
            target.{{ adapter.quote(key) }}
                = source.{{ adapter.quote(key) }}{% if not loop.last %} and {% endif %}
        {% endfor %}

        when matched then update set

            {#
                Preserve validations already inherited by the warehouse row,
                append the new warehouse-level findings, and remove duplicates.

                The typed empty array allows rows with a null validations column
                to participate in concat() without changing the struct schema.
            #}
            target.validations = array_distinct(
                concat(
                    coalesce(
                        target.validations,
                        cast(
                            array() as
                            {{ edu_edfi_source.validation_struct_type() }}
                        )
                    ),
                    source.validations
                )
            ),

            {#
                Compare the target row''s existing severity with the highest
                severity among the new findings.

                Each severity is converted to its configured numeric rank,
                greatest() selects the higher rank, and the resulting rank is
                converted back to its severity name.
            #}
            target.validation_severity =
                {% if severities | length > 0 %}
                    case greatest(
                        case target.validation_severity
                            {% for severity, rank in severities.items() %}
                            when '{{ severity }}' then {{ rank }}
                            {% endfor %}
                            else 0
                        end,

                        case source.validation_severity
                            {% for severity, rank in severities.items() %}
                            when '{{ severity }}' then {{ rank }}
                            {% endfor %}
                            else 0
                        end
                    )
                        {% for severity, rank in severities.items() %}
                        when {{ rank }} then '{{ severity }}'
                        {% endfor %}
                        else 'unknown'
                    end
                {% else %}
                    'unknown'
                {% endif %}

    {% endcall -%}

    {#
        The val_* node does not create a separate database relation. It mutates
        target_model and returns no relations of its own.
    #}
    {{ return({'relations': []}) }}

{%- endmaterialization %}