{% macro create_udfs() %}
  {{ return(adapter.dispatch('create_udfs', 'snowplow_fractribution')()) }}
{% endmacro %}


{% macro default__create_udfs() %}
    {% set trim_long_path %}
-- Returns the last snowplow__path_lookback_steps channels in the path if snowplow__path_lookback_steps > 0,
-- or the full path otherwise.
CREATE OR REPLACE FUNCTION {{target.schema}}.trim_long_path(path varchar(3000), snowplow__path_lookback_steps INTEGER)
    RETURNS varchar(3000)
    IMMUTABLE
    LANGUAGE plpythonu
as $$
    py_array = path.split(' > ')
    from_indx = 0
    if snowplow__path_lookback_steps > 0:
        from_indx = len(py_array)-snowplow__path_lookback_steps
    return ' > '.join(py_array[from_indx:])
    $$;
{% endset %}

      -- Functions for applying transformations to path varchar(3000)s.
      -- unique_path: Identity transform.
      --   E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, B, C, D, C, C].
      -- exposure_path: Collapse sequential repeats.
      --   E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, C, D, C].
      -- first_path: Removes repeated events.
      --   E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, C].
      -- frequency_path: Removes repeat events but tracks them with a count.
      --   E.g. [D, A, B, B, C, D, C, C] --> [D(2), A(1), B(2), C(3)).
      -- remove_if_last_and_not_all: requires a channel to be added as a parameter, which gets removed from the latest paths unless it removes the whole path as it is trying to reach a non-matching channel parameter
      --   E.g target element: `A`, path: `A → B → A → A` becomes `A → B`
      -- remove_if_not_all: requires a channel to be added as a parameter, which gets removed from the path altogether unless it would result in the whole path's removal.
      --   E.g target element: `A`, path: `A → B → A → A` becomes `B`


      {% set remove_if_not_all %}
-- Returns the path with all copies of targetElem removed, unless the path consists only of
-- targetElems, in which case the original path is returned.
CREATE OR REPLACE FUNCTION {{target.schema}}.remove_if_not_all(path varchar(3000), targetElem VARCHAR)
    RETURNS varchar(3000)
    IMMUTABLE
AS $$
        # Split the input string into a list of elements
        input_list = path.split(' > ')

        # Remove all instances of the target element from the end of the list
        while input_list and input_list[-1] == target_elem:
            input_list.pop()

        # If the list is empty, return the original string
        if not input_list:
            return path

        # Otherwise, join the remaining elements back into a string and return it
        return ' > '.join(input_list)
    $$ LANGUAGE plpythonu;
{% endset %}

      {% set remove_if_last_and_not_all %}
-- Returns the path with all copies of targetElem removed from the tail, unless the path consists
-- only of targetElems, in which case the original path is returned.
CREATE OR REPLACE FUNCTION {{target.schema}}.remove_if_last_and_not_all(path varchar(3000), targetElem VARCHAR)
    RETURNS varchar(3000)
    IMMUTABLE
AS $$
        # Split the input string into a list of elements
        input_list = path.split(' > ')

        # Remove all instances of the target element from the end of the list
        while input_list and input_list[-1] == target_elem:
            input_list.pop()

        # If the list is empty, return the original string
        if not input_list:
            return path

        # Otherwise, join the remaining elements back into a string and return it
        return ' > '.join(input_list)
    $$ LANGUAGE plpythonu;
{% endset %}

      {% set unique %}
-- Returns the unique/identity transform of the given path varchar(3000).
-- E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, B, C, D, C, C].
CREATE OR REPLACE FUNCTION {{target.schema}}.unique_path(path varchar(3000))
    RETURNS varchar(3000)
    IMMUTABLE
    LANGUAGE plpythonu
as $$
        return path;
    $$;
{% endset %}

    {% set exposure %}
-- Returns the exposure transform of the given path varchar(3000).
-- Sequential duplicates are collapsed.
-- E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, C, D, C].
CREATE OR REPLACE FUNCTION {{target.schema}}.exposure_path(path varchar(3000))
    RETURNS VARCHAR(3000) IMMUTABLE
AS $$
        input_list = path.split(' > ')
        output_list = []
        # Loop through the list, adding each unique element to the output list
        for i in range(len(input_list)):
            curr_elem = input_list[i]
            if curr_elem != input_list[i-1] or i == 0:
                output_list.append(curr_elem)

        return ' > '.join(output_list)
    $$ LANGUAGE plpythonu;
{% endset %}

      {% set first %}
-- Returns the first transform of the given path varchar(3000).
-- Repeated channels are removed.
-- E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, C].
CREATE OR REPLACE FUNCTION {{target.schema}}.first_path(path varchar(3000))
    RETURNS varchar(3000)
    IMMUTABLE
AS $$
        output_list = []
        input_list = path.split(' > ')

        # Loop through the input list, adding each unique element to the output list
        for i in range(len(input_list)):
            curr_elem = input_list[i]
            if curr_elem not in output_list:
                output_list.append(curr_elem)
        # Convert the output list to a comma-separated string
        output_str = ' > '.join(output_list)
        return output_str
    $$ LANGUAGE plpythonu;
{% endset %}

      {% set frequency %}
-- Returns the frequency transform of the given path varchar(3000).
-- Repeat events are removed, but tracked with a count.
-- E.g. [D, A, B, B, C, D, C, C] --> [D(2), A(1), B(2), C(3)].
CREATE OR REPLACE FUNCTION {{target.schema}}.frequency_path(path varchar(3000))
    RETURNS varchar(3000)
    IMMUTABLE
    LANGUAGE plpythonu
as $$
        element_list = []
        output_list = []
        input_list = path.split(' > ')

        # Loop through the input list, adding each unique element to the output list
        for i in range(len(input_list)):
            curr_elem = input_list[i]
            if curr_elem not in element_list:
                element_list.append(curr_elem)

        # Create a dictionary to store the frequency count of each element
        count_dict = {elem: 0 for elem in element_list}

        # Loop through the input list again, incrementing the count for each element
        for elem in input_list:
            if elem in count_dict:
                count_dict[elem] += 1

        # Create a list of the unique occurrence of each element with its frequency count
        for elem in element_list:
            output_list.append('{}({})'.format(elem,count_dict[elem]))

        # Convert the output list to a comma-separated string
        output_str = ' > '.join(output_list)

        return output_str
    $$;
{% endset %}


    {% set create_schema %}
create schema if not exists {{target.schema}};
{% endset %}

    -- create the udfs (as permanent UDFs)
    {% do run_query(create_schema) %} -- run this FIRST before the rest get run
    {% do run_query(trim_long_path) %}
    {% do run_query(remove_if_not_all) %}
    {% do run_query(remove_if_last_and_not_all) %}
    {% do run_query(unique) %}
    {% do run_query(exposure) %}
    {% do run_query(first) %}
    {% do run_query(frequency) %}
    -- have to return some valid sql
select 1;
{% endmacro %}

{% macro bigquery__create_udfs() %}

  {% set trim_long_path %}
  -- Returns the last snowplow__path_lookback_steps channels in the path if snowplow__path_lookback_steps > 0,
  -- or the full path otherwise.
  CREATE FUNCTION IF NOT EXISTS {{target.schema}}.trim_long_path(path ARRAY<string>, snowplow__path_lookback_steps INTEGER)
  RETURNS ARRAY<string>
  LANGUAGE js
  as r"""
  if (snowplow__path_lookback_steps > 0) {
      return path.slice(Math.max(0, path.length - snowplow__path_lookback_steps));
    }
    return path;
  """;
  {% endset %}

  -- Functions for applying transformations to path arrays.
  -- unique_path: Identity transform.
  --   E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, B, C, D, C, C].
  -- exposure_path: Collapse sequential repeats.
  --   E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, C, D, C].
  -- first_path: Removes repeated events.
  --   E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, C].
  -- frequency_path: Removes repeat events but tracks them with a count.
  --   E.g. [D, A, B, B, C, D, C, C] --> [D(2), A(1), B(2), C(3)).
  -- remove_if_last_and_not_all: requires a channel to be added as a parameter, which gets removed from the latest paths unless it removes the whole path as it is trying to reach a non-matching channel parameter
  --   E.g target element: `A`, path: `A → B → A → A` becomes `A → B`
  -- remove_if_not_all: requires a channel to be added as a parameter, which gets removed from the path altogether unless it would result in the whole path's removal.
  --   E.g target element: `A`, path: `A → B → A → A` becomes `B`


  {% set remove_if_not_all %}
  -- Returns the path with all copies of targetElem removed, unless the path consists only of
  -- targetElems, in which case the original path is returned.
  CREATE FUNCTION IF NOT EXISTS {{target.schema}}.remove_if_not_all(path ARRAY<string>, targetElem STRING)
  RETURNS ARRAY<string>
  LANGUAGE js
  as r"""
    var transformedPath = [];
    for (var i = 0; i < path.length; i++) {
      if (path[i] !== targetElem) {
        transformedPath.push(path[i]);
      }
    }
    if (!transformedPath.length) {
      return path;
    }
    return transformedPath;
  """;
  {% endset %}

  {% set remove_if_last_and_not_all %}
  -- Returns the path with all copies of targetElem removed from the tail, unless the path consists
  -- only of targetElems, in which case the original path is returned.
  CREATE FUNCTION IF NOT EXISTS {{target.schema}}.remove_if_last_and_not_all(path ARRAY<string>, targetElem STRING)
  RETURNS ARRAY<string>
  LANGUAGE js
  as r"""
    var tailIndex = path.length;
    for (var i = path.length - 1; i >= 0; i = i - 1) {
      if (path[i] != targetElem) {
        break;
      }
      tailIndex = i;
    }
    if (tailIndex > 0) {
      return path.slice(0, tailIndex);
    }
    return path;
  """;
  {% endset %}

  {% set unique %}
  -- Returns the unique/identity transform of the given path array.
  -- E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, B, C, D, C, C].
  CREATE FUNCTION IF NOT EXISTS {{target.schema}}.unique_path(path ARRAY<string>)
  RETURNS ARRAY<string>
  LANGUAGE js
  as r"""
    return path;
  """;
  {% endset %}

  {% set exposure %}
  -- Returns the exposure transform of the given path array.
  -- Sequential duplicates are collapsed.
  -- E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, C, D, C].
  CREATE FUNCTION IF NOT EXISTS {{target.schema}}.exposure_path(path ARRAY<string>)
  RETURNS ARRAY<string>
  LANGUAGE js
  as r"""
    var transformedPath = [];
    for (var i = 0; i < path.length; i++) {
      if (i == 0 || path[i] != path[i-1]) {
        transformedPath.push(path[i]);
      }
    }
    return transformedPath;
  """;
  {% endset %}

  {% set first %}
  -- Returns the first transform of the given path array.
  -- Repeated channels are removed.
  -- E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, C].
  CREATE FUNCTION IF NOT EXISTS {{target.schema}}.first_path(path ARRAY<string>)
  RETURNS ARRAY<string>
  LANGUAGE js
  as r"""
    var transformedPath = [];
    var channelSet = new Set();
    for (const channel of path) {
      if (!channelSet.has(channel)) {
        transformedPath.push(channel);
        channelSet.add(channel)
      }
    }
    return transformedPath;
  """;
  {% endset %}

  {% set frequency %}
  -- Returns the frequency transform of the given path array.
  -- Repeat events are removed, but tracked with a count.
  -- E.g. [D, A, B, B, C, D, C, C] --> [D(2), A(1), B(2), C(3)].
  CREATE FUNCTION IF NOT EXISTS {{target.schema}}.frequency_path(path ARRAY<string>)
  RETURNS ARRAY<string>
  LANGUAGE js
  as r"""
    var channelToCount = {};
    for (const channel of path) {
      if (!(channel in channelToCount)) {
        channelToCount[channel] = 1
      } else {
        channelToCount[channel] +=1
      }
    }
    var transformedPath = [];
    for (const channel of path) {
      count = channelToCount[channel];
      if (count > 0) {
        transformedPath.push(channel + '(' + count.toString() + ')');
        // Reset count to 0, since the output has exactly one copy of each event.
        channelToCount[channel] = 0;
      }
    }
    return transformedPath;
  """;
  {% endset %}


  {% set create_schema %}
      create schema if not exists {{target.schema}};
  {% endset %}

  -- create the udfs (as permanent UDFs)
  {% do run_query(create_schema) %} -- run this FIRST before the rest get run
  {% do run_query(trim_long_path) %}
  {% do run_query(remove_if_not_all) %}
  {% do run_query(remove_if_last_and_not_all) %}
  {% do run_query(unique) %}
  {% do run_query(exposure) %}
  {% do run_query(first) %}
  {% do run_query(frequency) %}
  -- have to return some valid sql
  select 1;

{% endmacro %}


{% macro spark__create_udfs() %}
{% endmacro %}

{% macro snowflake__create_udfs(schema_suffix = '_derived') %}

  {% set trim_long_path %}
  -- Returns the last snowplow__path_lookback_steps channels in the path if snowplow__path_lookback_steps > 0,
  -- or the full path otherwise.
  CREATE FUNCTION IF NOT EXISTS {{target.schema}}.trim_long_path(path ARRAY, snowplow__path_lookback_steps DOUBLE)
  RETURNS ARRAY LANGUAGE JAVASCRIPT AS $$
  if (SNOWPLOW__PATH_LOOKBACK_STEPS > 0) {
      return PATH.slice(Math.max(0, PATH.length - SNOWPLOW__PATH_LOOKBACK_STEPS));
    }
    return PATH;
  $$;
  {% endset %}


  -- Functions for applying transformations to path arrays.
  -- unique_path: Identity transform.
  --   E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, B, C, D, C, C].
  -- exposure_path: Collapse sequential repeats.
  --   E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, C, D, C].
  -- first_path: Removes repeated events.
  --   E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, C].
  -- frequency_path: Removes repeat events but tracks them with a count.
  --   E.g. [D, A, B, B, C, D, C, C] --> [D(2), A(1), B(2), C(3)).
  -- remove_if_last_and_not_all: requires a channel to be added as a parameter, which gets removed from the latest paths unless it removes the whole path as it is trying to reach a non-matching channel parameter
  --   E.g target element: `A`, path: `A → B → A → A` becomes `A → B`
  -- remove_if_not_all: requires a channel to be added as a parameter, which gets removed from the path altogether unless it would result in the whole path's removal.
  --   E.g target element: `A`, path: `A → B → A → A` becomes `B`

  {% set remove_if_not_all %}
  -- Returns the path with all copies of targetElem removed, unless the path consists only of
  -- targetElems, in which case the original path is returned.
  CREATE FUNCTION IF NOT EXISTS {{target.schema}}.remove_if_not_all(path ARRAY, targetElem STRING)
  RETURNS ARRAY
  LANGUAGE JAVASCRIPT AS $$
    var transformedPath = [];
    for (var i = 0; i < PATH.length; i++) {
      if (PATH[i] !== TARGETELEM) {
        transformedPath.push(PATH[i]);
      }
    }
    if (!transformedPath.length) {
      return PATH;
    }
    return transformedPath;
  $$;
  {% endset %}

  {% set remove_if_last_and_not_all %}
  -- Returns the path with all copies of targetElem removed from the tail, unless the path consists
  -- only of targetElems, in which case the original path is returned.
  CREATE FUNCTION IF NOT EXISTS {{target.schema}}.remove_if_last_and_not_all(path ARRAY, targetElem STRING)
  RETURNS ARRAY
  LANGUAGE JAVASCRIPT AS $$
    var tailIndex = PATH.length;
    for (var i = PATH.length - 1; i >= 0; i = i - 1) {
      if (PATH[i] != TARGETELEM) {
        break;
      }
      tailIndex = i;
    }
    if (tailIndex > 0) {
      return PATH.slice(0, tailIndex);
    }
    return PATH;
  $$;
  {% endset %}

  {% set unique %}
  -- Returns the unique/identity transform of the given path array.
  -- E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, B, C, D, C, C].
  CREATE FUNCTION IF NOT EXISTS {{target.schema}}.unique_path(path ARRAY)
  RETURNS ARRAY
  LANGUAGE JAVASCRIPT AS $$
    return PATH;
  $$;
  {% endset %}

  {% set exposure %}
  -- Returns the exposure transform of the given path array.
  -- Sequential duplicates are collapsed.
  -- E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, C, D, C].
  CREATE FUNCTION IF NOT EXISTS {{target.schema}}.exposure_path(path ARRAY)
  RETURNS ARRAY
  LANGUAGE JAVASCRIPT AS $$
    var transformedPath = [];
    for (var i = 0; i < PATH.length; i++) {
      if (i == 0 || PATH[i] != PATH[i-1]) {
        transformedPath.push(PATH[i]);
      }
    }
    return transformedPath;
  $$;
  {% endset %}

  {% set first %}
  -- Returns the first transform of the given path array.
  -- Repeated channels are removed.
  -- E.g. [D, A, B, B, C, D, C, C] --> [D, A, B, C].
  CREATE FUNCTION IF NOT EXISTS {{target.schema}}.first_path(path ARRAY)
  RETURNS ARRAY
  LANGUAGE JAVASCRIPT AS $$
    var transformedPath = [];
    var channelSet = new Set();
    for (const channel of PATH) {
      if (!channelSet.has(channel)) {
        transformedPath.push(channel);
        channelSet.add(channel)
      }
    }
    return transformedPath;
  $$;
  {% endset %}

  {% set frequency %}
  -- Returns the frequency transform of the given path array.
  -- Repeat events are removed, but tracked with a count.
  -- E.g. [D, A, B, B, C, D, C, C] --> [D(2), A(1), B(2), C(3)].
  CREATE FUNCTION IF NOT EXISTS {{target.schema}}.frequency_path(path ARRAY)
  RETURNS ARRAY
  LANGUAGE JAVASCRIPT AS $$
    var channelToCount = {};
    for (const channel of PATH) {
      if (!(channel in channelToCount)) {
        channelToCount[channel] = 1
      } else {
        channelToCount[channel] +=1
      }
    }
    var transformedPath = [];
    for (const channel of PATH) {
      count = channelToCount[channel];
      if (count > 0) {
        transformedPath.push(channel + '(' + count.toString() + ')');
        // Reset count to 0, since the output has exactly one copy of each event.
        channelToCount[channel] = 0;
      }
    }
    return transformedPath;
  $$;
  {% endset %}


  {% set create_schema %}
      create schema if not exists {{target.schema}};
  {% endset %}

  -- create the udfs (as permanent UDFs)
  {% do run_query(create_schema) %} -- run this FIRST before the rest get run
  {% do run_query(trim_long_path) %}
  {% do run_query(remove_if_not_all) %}
  {% do run_query(remove_if_last_and_not_all) %}
  {% do run_query(unique) %}
  {% do run_query(exposure) %}
  {% do run_query(first) %}
  {% do run_query(frequency) %}
  -- have to return some valid sql
  select 1;
{% endmacro %}
