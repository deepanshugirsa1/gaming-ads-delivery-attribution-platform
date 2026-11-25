{#
    Small cross-warehouse helpers.

    The project runs on DuckDB locally and BigQuery as the real target. Most SQL is
    identical, and where dbt ships a cross-database macro (dbt.datediff,
    dbt.dateadd, dbt.date_trunc) this project uses it. These two cases are the ones
    dbt does not cover, so they are wrapped once here rather than branched inline
    in twenty models.
#}


{#
    Division that returns null instead of failing or returning infinity when the
    denominator is zero or null. Every rate in this project (CTR, CVR, fill rate,
    win rate, variance percentage) goes through this.

    BigQuery raises a division-by-zero error; DuckDB does not. Rather than relying
    on either behaviour, the guard is explicit: a rate with no denominator is
    unknown, not zero, and null is the honest representation. A campaign-day with
    zero impressions has no CTR -- reporting 0% would wrongly drag down any average
    computed over it.
#}
{% macro safe_div(numerator, denominator) -%}
    case
        when ({{ denominator }}) is null or ({{ denominator }}) = 0 then null
        else ({{ numerator }}) * 1.0 / ({{ denominator }})
    end
{%- endmacro %}


{#
    Approximate percentile as an aggregate, for the feature-distribution monitoring
    models. BigQuery exposes percentiles through approx_quantiles(); DuckDB through
    quantile_cont(). Both ignore nulls, which is what we want -- null rate is
    tracked as its own metric, so it should not also distort the distribution.

    fraction is in [0, 1]: pctl('value', 0.95) is the p95.
#}
{% macro pctl(column_name, fraction) -%}
    {%- if target.type == 'bigquery' -%}
        approx_quantiles({{ column_name }}, 100)[offset({{ (fraction * 100) | round | int }})]
    {%- else -%}
        quantile_cont({{ column_name }}, {{ fraction }})
    {%- endif -%}
{%- endmacro %}


{#
    A decimal type with six fractional digits that means the same thing on both
    targets.

    This is not pedantry. A CPM bid of $4.20 bills at $0.00420 per impression, and
    BigQuery's NUMERIC (38 digits, 9 fractional) holds that fine -- but DuckDB's
    bare NUMERIC defaults to DECIMAL(18,3), which rounds $0.00420 to $0.004. On a
    million impressions that is a 5% error in reported spend, appearing only on the
    local target, which is the worst possible place for a discrepancy to hide.

    Used for money and for rates stored at source (predicted CTR), so the two
    warehouses produce byte-identical aggregates from identical input.
#}
{% macro decimal6() -%}
    {%- if target.type == 'bigquery' -%}
        numeric
    {%- else -%}
        decimal(18, 6)
    {%- endif -%}
{%- endmacro %}
