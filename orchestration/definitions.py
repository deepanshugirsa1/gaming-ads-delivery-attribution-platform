"""Dagster orchestration for the dbt project.

NOT YET VERIFIED. This file is written against the dagster-dbt API but has not been
executed. It is listed under "not yet verified" in the README and must not be claimed
anywhere until `dagster dev` has run it and the asset graph has materialized. The rest
of this repository follows the rule that nothing is claimed until it has been run;
this file is the one place where the code exists ahead of the evidence, and it says so.

Why Dagster rather than the Airflow DAG the engagement half would have used: the two
reporting surfaces in this project have genuinely different cadences. Hourly delivery
needs to be current within the hour; attribution and the ML tables cannot be final
until the conversion window closes. Modelling that as two schedules over one asset
graph, rather than one DAG that rebuilds everything, is the whole point.

Run locally:
    pip install -r requirements-orchestration.txt
    dbt parse --profiles-dir .
    dagster dev -f orchestration/definitions.py
"""

from pathlib import Path

from dagster import AssetSelection, Definitions, ScheduleDefinition, define_asset_job
from dagster_dbt import DbtCliResource, DbtProject, dbt_assets

PROJECT_DIR = Path(__file__).parent.parent

dbt_project = DbtProject(
    project_dir=PROJECT_DIR,
    profiles_dir=PROJECT_DIR,
    target="duckdb",
)
dbt_project.prepare_if_dev()

dbt_resource = DbtCliResource(project_dir=dbt_project)


@dbt_assets(manifest=dbt_project.manifest_path)
def gaming_ads_dbt_assets(context, dbt: DbtCliResource):
    """Every dbt model, test and seed as a Dagster asset."""
    yield from dbt.cli(["build"], context=context).stream()


# Hourly: the low-latency delivery path only. Selecting a subset rather than rebuilding
# everything is the reason this is worth orchestrating at all -- the attribution and ML
# tables have nothing to gain from running twelve times before their labels mature.
hourly_delivery_job = define_asset_job(
    name="hourly_delivery",
    selection=AssetSelection.keys("agg_ad_delivery_hourly").upstream(),
)

# Daily: the whole graph, including attribution, measurement parity and the ML tables.
daily_full_job = define_asset_job(name="daily_full_refresh", selection=AssetSelection.all())

defs = Definitions(
    assets=[gaming_ads_dbt_assets],
    resources={"dbt": dbt_resource},
    jobs=[hourly_delivery_job, daily_full_job],
    schedules=[
        ScheduleDefinition(job=hourly_delivery_job, cron_schedule="7 * * * *"),
        # After the hour the last late conversions of the previous day can arrive.
        ScheduleDefinition(job=daily_full_job, cron_schedule="40 4 * * *"),
    ],
)
