with stage_program_services as (
    select * from {{ ref('stg_ef3__stu_homeless__program_services') }}
),

wide as (
    select 
        tenant_code,
        api_year,
        k_student,
        k_student_xyear,
        k_program,
        k_lea,
        k_school,
        program_enroll_begin_date,
        array_agg(program_service) as program_services
    from (
        select distinct
            tenant_code,
            api_year,
            k_student,
            k_student_xyear,
            k_program,
            k_lea,
            k_school,
            program_enroll_begin_date,
            program_service
        from stage_program_services
        order by program_service
    )
    
    {{ dbt_utils.group_by(n=8) }}
)

select * from wide
