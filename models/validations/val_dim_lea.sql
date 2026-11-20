{{ edu_edfi_source.apply_validations(
    materialization='edu_wh_validation_merge',
    target_model='dim_lea',
    target_keys=['k_lea']
) }}