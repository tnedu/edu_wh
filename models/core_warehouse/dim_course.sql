-- SPDX-FileCopyrightText: 2022 Education Analytics
-- SPDX-License-Identifier: MPL-2.0

{{
  config(
    post_hook=[
        "alter table {{ this }} alter column k_course set not null",
        "alter table {{ this }} add primary key (k_course)",
    ]
  )
}}

{{ cds_depends_on('edu:course:custom_data_sources') }}
{% set custom_data_sources = var('edu:course:custom_data_sources', []) %}

with stg_course as (
    select * from {{ ref('stg_ef3__courses') }}
),
bld_ef3__wide_ids_course as (
    select * from {{ ref('bld_ef3__wide_ids_course') }}
),
bld_ef3__course_subject as (
    select * from {{ ref('bld_ef3__course_subject') }}
),
course_chars as (
    select * from {{ ref('bld_ef3__course__wide_course_characteristics') }}
),
formatted as (
    select 
        stg_course.k_course,
        stg_course.tenant_code,
        stg_course.school_year,
        stg_course.course_code,
        stg_course.course_title,
        {{ accordion_columns(
            source_table='bld_ef3__wide_ids_course', 
            exclude_columns=['tenant_code', 'api_year', 'k_course']) }}
        stg_course.course_description,
        stg_course.k_lea,
        stg_course.k_school,
        stg_course.ed_org_id,
        stg_course.ed_org_type,
        bld_ef3__course_subject.academic_subject,
        stg_course.career_pathway,
        stg_course.course_defined_by,
        stg_course.gpa_applicability,
        stg_course.date_course_adopted,
        stg_course.is_high_school_course_requirement,
        stg_course.max_completions_for_credit,
        stg_course.maximum_available_credits,
        stg_course.maximum_available_credit_type,
        stg_course.maximum_available_credit_conversion,
        stg_course.minimum_available_credits,
        stg_course.minimum_available_credit_type,
        stg_course.minimum_available_credit_conversion,
        stg_course.number_of_parts,
        stg_course.time_required_for_completion,

          -- course characteristics
        {{ accordion_columns(
            source_table='bld_ef3__course__wide_course_characteristics',
            exclude_columns=['tenant_code', 'api_year', 'k_course', 'course_characteristics_array'],
            source_alias='course_chars',
            coalesce_value = 'FALSE'
        ) }}
        course_chars.course_characteristics_array,

        bld_ef3__course_subject.subject_array
        -- custom data sources columns
        {{ add_cds_columns(custom_data_sources=custom_data_sources) }}

    from stg_course
    left join bld_ef3__wide_ids_course 
        on stg_course.k_course = bld_ef3__wide_ids_course.k_course
    left join bld_ef3__course_subject
        on stg_course.k_course = bld_ef3__course_subject.k_course
    left join course_chars
        on stg_course.k_course = course_chars.k_course
    
    -- custom data sources
    {{ add_cds_joins_v1(custom_data_sources=custom_data_sources, driving_alias='stg_course', join_cols=['k_course']) }}
    {{ add_cds_joins_v2(custom_data_sources=custom_data_sources) }}
)
select * from formatted
order by tenant_code, school_year desc, k_course
