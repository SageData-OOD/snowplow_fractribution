{{
  config(
    sql_header=snowplow_utils.set_query_tag(var('snowplow__query_tag', 'snowplow_dbt'))
  )
}}

-- Requires macro trim_long_path

with string_aggs as (

  select
    c.customer_id,
    c.conversion_tstamp,
    c.revenue,
    {{ snowplow_utils.get_string_agg('channel', 's', separator=' > ', sort_numeric=false, order_by_column='visit_start_tstamp', order_by_column_prefix='s') }} as path

  from {{ ref('snowplow_fractribution_conversions_by_customer_id') }} c

  inner join {{ ref('snowplow_fractribution_sessions_by_customer_id') }} s
  on c.customer_id = s.customer_id
    and {{ datediff('s.visit_start_tstamp', 'c.conversion_tstamp', 'day') }}  >= 0
    and {{ datediff('s.visit_start_tstamp', 'c.conversion_tstamp', 'day') }} <= {{ var('snowplow__path_lookback_days') }}

  group by 1,2,3

)

   -- SageData Modification for Redshift
   -- in reality we do not need to convert the path to array and then back as this is done in Redshift UDFs
   -- therefore the bellow optional conversions to and from array are not done for redshift
    {% if target.type == 'redshift' %}

    , arrays as (
      select
        customer_id,
        conversion_tstamp,
        revenue,
        path,
        path as transformed_path

      from string_aggs s
    )

    {{ transform_paths('conversions', 'arrays') }}

    select
        customer_id,
        conversion_tstamp,
        revenue,
        path,
        transformed_path

    from path_transforms p

    {% else %}

, arrays as (

  select
    customer_id,
    conversion_tstamp,
    revenue,
    {{ snowplow_utils.get_split_to_array('path', 's', ' > ') }} as path,
    {{ snowplow_utils.get_split_to_array('path', 's', ' > ') }} as transformed_path

  from string_aggs s

)

{{ transform_paths('conversions', 'arrays') }}

select
  customer_id,
  conversion_tstamp,
  revenue,
  {{ snowplow_utils.get_array_to_string('path', 'p', ' > ') }} as path,
  {{ snowplow_utils.get_array_to_string('transformed_path', 'p', ' > ') }} as transformed_path

from path_transforms p
    {% endif %}

-- End SageData modification
