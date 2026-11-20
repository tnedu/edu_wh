{{ edu_edfi_source.apply_validations(
    materialization='edu_wh_validation_merge',
    target_model='dim_school',
    target_keys=['k_school']
) }}