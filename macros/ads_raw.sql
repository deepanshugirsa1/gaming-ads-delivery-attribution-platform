{#
    Resolves a raw ad-event feed to a readable relation for the active target.

    Why this exists: the engagement half of this project is small enough to ship
    as dbt seeds in git. The ads half is not -- a single run generates millions of
    impression rows, which do not belong in version control. So the ad feeds are
    generated to disk and read as sources instead:

      * BigQuery -- native tables in the `ads_raw` dataset, loaded by
        scripts/load_bigquery.sh with an explicit JSON schema per table.
      * DuckDB   -- the same gzipped CSV files read straight off disk.

    all_varchar=true on the DuckDB path is deliberate. CSV type inference samples
    rows, so a column that is null for the first few thousand rows (claimed_user_id,
    for instance) can be inferred as a different type than BigQuery assigns it.
    Reading everything as text and casting explicitly in staging makes the two
    warehouses produce identical types from identical files, and keeps typing in
    the one layer that is supposed to own it.
#}

{% macro ads_raw(table_name) -%}
    {%- if target.type == 'duckdb' -%}
        read_csv_auto('{{ var("ads_raw_path") }}/{{ table_name }}/*.csv.gz', all_varchar=true)
    {%- elif target.type == 'bigquery' -%}
        `{{ target.project }}.{{ var("ads_raw_dataset") }}.{{ table_name }}`
    {%- else -%}
        {{ exceptions.raise_compiler_error(
            "ads_raw() supports duckdb and bigquery; got target.type = " ~ target.type
        ) }}
    {%- endif -%}
{%- endmacro %}
