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

    {%- set validation_enabled =
        validation_config.get('enabled', false)
    -%}

    {%- set rules =
        validation_config.get('models', {}).get(model_name, [])
    -%}

    {%- if validation_enabled and rules | length > 0 -%}

        {# Derive the validation-merge node associated with this model. #}
        {%- set validation_model =
            'val_' ~ model_name | replace('stg_', '')
        -%}

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
    Combines validation results from one or more upstream models and appends
    them to a warehouse model.

    Only validations whose severity appears in the configured severities map
    are propagated. The filtered validation array is also used to calculate
    validation_severity, ensuring the summary can never represent a validation
    that was stripped during warehouse propagation.

    For example, if "advisory" is not configured as a propagating severity:
      - advisory findings are removed from validations;
      - if no other findings remain, validations is empty; and
      - validation_severity falls back to default_severity, normally null.

    If no severities are configured, no validations are propagated.

    The leading comma is intentional so this macro can be appended directly to
    an existing SELECT column list.
#}
{% macro combine_validations(sources) -%}

    {%- set validation_config = var('edu:data_validation', {}) -%}
    {%- set severities = validation_config.get('severities', {}) -%}

    {%- if validation_config.get('enabled', false)
        and validation_config.get('append_to_warehouse_models', false) %}

        ,

        {#
            Build the combined validation array. Configured severities act as
            the allowlist for warehouse propagation.
        #}
        array_distinct(
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
        ) as validations,

        {#
            Calculate severity directly from the same validations that survive
            warehouse filtering.

            transform() converts each propagated validation to its configured
            numeric severity rank. array_max() selects the highest rank, and
            the CASE maps that rank back to its severity name.

            When no validations survive, array_max() returns null and the
            configured default_severity is used instead.
        #}
        coalesce(
            {% if severities | length > 0 %}

                case array_max(
                    transform(
                        array_distinct(
                            flatten(
                                array(
                                    {% for source in sources %}
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
                                    ){% if not loop.last %},{% endif %}
                                    {% endfor %}
                                )
                            )
                        ),
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

    When edu:data_validation.severities is configured, its numeric ranks define
    the ordering used to select the highest severity. If no severity ranking is
    configured, the framework cannot reliably compare findings and assigns
    "unknown" to validation_severity.

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

                {# Collect all newly generated findings for the target row. #}
                collect_list(validation) as validations,

                {#
                    Determine the highest severity among the new findings.

                    Severities not present in the configured ranking receive
                    rank 0. If no ranking is configured, their relative
                    importance cannot be determined.
                #}
                {% if severities | length > 0 %}
                    max_by(
                        validation.severity,
                        case validation.severity
                            {% for severity, rank in severities.items() %}
                            when '{{ severity }}' then {{ rank }}
                            {% endfor %}
                            else 0
                        end
                    )
                {% else %}
                    'unknown'
                {% endif %} as validation_severity

            from (
                {#
                    sql contains the UNION ALL of warehouse validator models
                    generated by validation_models_for().
                #}
                {{ sql }}
            ) as validation_rows

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
                Compare the target row's existing severity with the highest
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