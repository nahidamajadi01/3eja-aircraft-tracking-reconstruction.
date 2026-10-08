SELECT *
FROM raw_faa_fleet
WHERE "DSGN" = '3EJA';
SELECT *
FROM read_csv(
    '/Users/nahidaqueen/Desktop/aviation_project/registry/MASTER.txt',
    header = true,
    all_varchar = true
)
LIMIT 5;



SELECT
    fleet."Registration No.",
    fleet."Aircraft M/M/S",
    registry."MODE S CODE HEX" AS hex_code
FROM raw_faa_fleet AS fleet
LEFT JOIN raw_faa_registry AS registry
    ON regexp_replace(
        UPPER(TRIM(fleet."Registration No.")),
        '^N',
        ''
    ) = UPPER(TRIM(registry."N-NUMBER"))
WHERE fleet."DSGN" = '3EJA'
ORDER BY fleet."Registration No.";

 SELECT *
FROM read_json_objects(
    '/Users/nahidaqueen/Desktop/aviation_project/tracking/*.json',
    format = 'unstructured'
);

SELECT
    json_extract_string(json, '$.icao') AS hex_code,
    json_extract(json, '$.timestamp') AS reference_time,
    json_extract(json, '$.trace[0]') AS first_tracking_point
FROM read_json_objects(
    '/Users/nahidaqueen/Desktop/aviation_project/tracking/*.json',
    format = 'unstructured'
);


WITH positions AS (
    SELECT
        json_extract_string(raw.json, '$.icao') AS hex_code,
        CAST(point.key AS INTEGER) AS point_index,

        CAST(
            json_extract_string(raw.json, '$.timestamp')
            AS DOUBLE
        ) AS reference_seconds,

        CAST(point.value ->> '$[0]' AS DOUBLE) AS offset_seconds,
        CAST(point.value ->> '$[1]' AS DOUBLE) AS latitude,
        CAST(point.value ->> '$[2]' AS DOUBLE) AS longitude,
        point.value ->> '$[3]' AS altitude_raw,
        CAST(point.value ->> '$[4]' AS DOUBLE) AS ground_speed_knots,
        CAST(point.value ->> '$[6]' AS INTEGER) AS flags

    FROM read_json_objects(
        '/Users/nahidaqueen/Desktop/aviation_project/tracking/*.json',
        format = 'unstructured'
    ) AS raw,
    LATERAL json_each(raw.json, '$.trace') AS point
)
SELECT
    hex_code,
    point_index,
    to_timestamp(reference_seconds + offset_seconds)
        AT TIME ZONE 'UTC' AS recorded_at_utc,
    latitude,
    longitude,
    altitude_raw,
    ground_speed_knots,
    flags,
    (flags & 1) = 1 AS is_stale,
    (flags & 2) = 2 AS is_new_leg_hint,
    (flags & 8) = 8 AS altitude_is_geometric
FROM positions
ORDER BY hex_code, point_index
LIMIT 10;



CREATE TABLE stg_adsb_positions AS

WITH positions AS (
    SELECT
        json_extract_string(raw.json, '$.icao') AS hex_code,
        CAST(point.key AS INTEGER) AS point_index,

        CAST(
            json_extract_string(raw.json, '$.timestamp')
            AS DOUBLE
        ) AS reference_seconds,

        CAST(point.value ->> '$[0]' AS DOUBLE) AS offset_seconds,
        CAST(point.value ->> '$[1]' AS DOUBLE) AS latitude,
        CAST(point.value ->> '$[2]' AS DOUBLE) AS longitude,
        point.value ->> '$[3]' AS altitude_raw,
        CAST(point.value ->> '$[4]' AS DOUBLE) AS ground_speed_knots,
        CAST(point.value ->> '$[6]' AS INTEGER) AS flags

    FROM read_json_objects(
        '/Users/nahidaqueen/Desktop/aviation_project/tracking/*.json',
        format = 'unstructured'
    ) AS raw,
    LATERAL json_each(raw.json, '$.trace') AS point
)

SELECT
    hex_code,
    point_index,
    to_timestamp(reference_seconds + offset_seconds)
        AT TIME ZONE 'UTC' AS recorded_at_utc,
    latitude,
    longitude,
    altitude_raw,
    ground_speed_knots,
    flags,
    (flags & 1) = 1 AS is_stale,
    (flags & 2) = 2 AS is_new_leg_hint,
    (flags & 8) = 8 AS altitude_is_geometric
FROM positions
ORDER BY hex_code, point_index;

SELECT COUNT(*) AS tracking_points
FROM stg_adsb_positions;


SELECT *
FROM stg_adsb_positions
ORDER BY hex_code, recorded_at_utc;



SELECT
    hex_code,
    altitude_raw,
    COUNT(*) AS number_of_points,
    MIN(ground_speed_knots) AS lowest_speed,
    MAX(ground_speed_knots) AS highest_speed
FROM stg_adsb_positions
GROUP BY hex_code, altitude_raw
ORDER BY hex_code, altitude_raw;



SELECT
    hex_code,
    CASE
        WHEN altitude_raw = 'ground' THEN 'reported_ground'
        WHEN altitude_raw IS NULL THEN 'missing_altitude'
        ELSE 'numeric_altitude'
    END AS altitude_category,
    COUNT(*) AS number_of_points,
    MIN(ground_speed_knots) AS lowest_speed,
    MAX(ground_speed_knots) AS highest_speed
FROM stg_adsb_positions
GROUP BY hex_code, altitude_category
ORDER BY hex_code, altitude_category;




SELECT
    hex_code,
    point_index,
    recorded_at_utc,
    altitude_raw,
    ground_speed_knots,
    CASE
        WHEN altitude_raw = 'ground'
             AND ground_speed_knots < 60
            THEN 'ground'
        WHEN TRY_CAST(altitude_raw AS DOUBLE) IS NOT NULL
             AND ground_speed_knots >= 60
            THEN 'flying'
        ELSE 'uncertain'
    END AS movement_state
FROM stg_adsb_positions
ORDER BY hex_code, recorded_at_utc, point_index;




WITH labelled_points AS (
    SELECT
        *,
        CASE
            WHEN altitude_raw = 'ground'
                 AND ground_speed_knots < 60
                THEN 'ground'
            WHEN TRY_CAST(altitude_raw AS DOUBLE) IS NOT NULL
                 AND ground_speed_knots >= 60
                THEN 'flying'
            ELSE 'uncertain'
        END AS movement_state
    FROM stg_adsb_positions
),
compared_points AS (
    SELECT
        *,
        LAG(movement_state) OVER (
            PARTITION BY hex_code
            ORDER BY recorded_at_utc, point_index
        ) AS previous_state,
        LAG(recorded_at_utc) OVER (
            PARTITION BY hex_code
            ORDER BY recorded_at_utc, point_index
        ) AS previous_time_utc
    FROM labelled_points
)
SELECT
    hex_code,
    previous_time_utc,
    recorded_at_utc,
    previous_state,
    movement_state,
    altitude_raw,
    ground_speed_knots
FROM compared_points
WHERE previous_state IS NULL
   OR movement_state <> previous_state
ORDER BY hex_code, recorded_at_utc, point_index;



WITH neighbouring_points AS (
    SELECT
        hex_code,
        point_index,
        recorded_at_utc,
        altitude_raw,
        ground_speed_knots,
        LAG(recorded_at_utc) OVER aircraft_order AS previous_time,
        LEAD(recorded_at_utc) OVER aircraft_order AS next_time,
        LAG(altitude_raw) OVER aircraft_order AS previous_altitude,
        LEAD(altitude_raw) OVER aircraft_order AS next_altitude,
        LAG(ground_speed_knots) OVER aircraft_order AS previous_speed,
        LEAD(ground_speed_knots) OVER aircraft_order AS next_speed
    FROM stg_adsb_positions
    WINDOW aircraft_order AS (
        PARTITION BY hex_code
        ORDER BY recorded_at_utc, point_index
    )
)
SELECT
    *,
    ROUND(
        EXTRACT(EPOCH FROM (recorded_at_utc - previous_time)),
        1
    ) AS seconds_since_previous,
    ROUND(
        EXTRACT(EPOCH FROM (next_time - recorded_at_utc)),
        1
    ) AS seconds_until_next
FROM neighbouring_points
WHERE ground_speed_knots IS NULL
ORDER BY hex_code, recorded_at_utc, point_index;



WITH gap_check AS (
    SELECT
        hex_code,
        recorded_at_utc,
        altitude_raw,
        LAG(recorded_at_utc) OVER aircraft_order AS previous_time,
        LAG(altitude_raw) OVER aircraft_order AS previous_altitude
    FROM stg_adsb_positions
    WINDOW aircraft_order AS (
        PARTITION BY hex_code
        ORDER BY recorded_at_utc, point_index
    )
)
SELECT
    hex_code,
    previous_time,
    recorded_at_utc AS current_time,
    previous_altitude,
    altitude_raw AS current_altitude,
    ROUND(
        EXTRACT(EPOCH FROM (recorded_at_utc - previous_time)),
        1
    ) AS gap_seconds
FROM gap_check
WHERE recorded_at_utc - previous_time > INTERVAL '120 seconds'
ORDER BY hex_code, recorded_at_utc;




CREATE VIEW int_adsb_flight_points AS
SELECT
    *,
    CASE
        WHEN altitude_raw = 'ground' THEN 'reported_ground'
        WHEN TRY_CAST(altitude_raw AS DOUBLE) IS NOT NULL
            THEN 'airborne_candidate'
        ELSE 'unknown'
    END AS flight_state,
    LAG(altitude_raw) OVER aircraft_order AS previous_altitude,
    LEAD(altitude_raw) OVER aircraft_order AS next_altitude,
    LAG(recorded_at_utc) OVER aircraft_order AS previous_time,
    LEAD(recorded_at_utc) OVER aircraft_order AS next_time,
    EXTRACT(EPOCH FROM (
        recorded_at_utc
        - LAG(recorded_at_utc) OVER aircraft_order
    )) AS gap_seconds
FROM stg_adsb_positions
WINDOW aircraft_order AS (
    PARTITION BY hex_code
    ORDER BY recorded_at_utc, point_index
);



WITH flight_starts AS (
    SELECT
        *,
        CASE
            WHEN flight_state = 'airborne_candidate'
                 AND TRY_CAST(previous_altitude AS DOUBLE) IS NULL
                THEN 1
            ELSE 0
        END AS starts_new_flight
    FROM int_adsb_flight_points
),
numbered_points AS (
    SELECT
        *,
        SUM(starts_new_flight) OVER (
            PARTITION BY hex_code
            ORDER BY recorded_at_utc, point_index
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS flight_number
    FROM flight_starts
),
flight_summary AS (
    SELECT
        hex_code,
        flight_number,
        MIN(recorded_at_utc) AS first_airborne_time,
        MAX(recorded_at_utc) AS last_airborne_time,

        (
            FIRST(previous_altitude ORDER BY recorded_at_utc, point_index)
                IS DISTINCT FROM 'ground'
            OR COALESCE(
                FIRST(gap_seconds ORDER BY recorded_at_utc, point_index) > 120,
                TRUE
            )
        ) AS missing_departure,

        (
            LAST(next_altitude ORDER BY recorded_at_utc, point_index)
                IS DISTINCT FROM 'ground'
            OR COALESCE(
                EXTRACT(EPOCH FROM (
                    LAST(next_time ORDER BY recorded_at_utc, point_index)
                    - MAX(recorded_at_utc)
                )) > 120,
                TRUE
            )
        ) AS missing_arrival,

        BOOL_OR(
            gap_seconds > 120
            AND TRY_CAST(previous_altitude AS DOUBLE) IS NOT NULL
        ) AS internal_gap

    FROM numbered_points
    WHERE flight_state = 'airborne_candidate'
    GROUP BY hex_code, flight_number
)
SELECT
    hex_code,
    flight_number,
    first_airborne_time,
    last_airborne_time,
    CASE
        WHEN NOT missing_departure
             AND NOT missing_arrival
             AND NOT internal_gap
            THEN 'No tracking problem found'
        ELSE CONCAT_WS(
            '; ',
            CASE WHEN missing_departure THEN 'Departure not observed' END,
            CASE WHEN missing_arrival THEN 'Arrival not observed' END,
            CASE WHEN internal_gap THEN 'Gap during flight' END
        )
    END AS tracking_problem
FROM flight_summary
ORDER BY hex_code, first_airborne_time;

SELECT *
FROM read_csv_auto(
    '/Users/nahidaqueen/Desktop/aviation_project/airports.csv'
)
LIMIT 5;


CREATE TABLE IF NOT EXISTS raw_airports AS
SELECT *
FROM read_csv_auto(
    '/Users/nahidaqueen/Desktop/aviation_project/airports.csv'
);
CREATE OR REPLACE VIEW int_flight_airport_matches AS
WITH flight_starts AS (
    SELECT *,
        CASE
            WHEN flight_state = 'airborne_candidate'
             AND TRY_CAST(previous_altitude AS DOUBLE) IS NULL
            THEN 1
            ELSE 0
        END AS starts_new_flight
    FROM int_adsb_flight_points
),

numbered_points AS (
    SELECT *,
        SUM(starts_new_flight) OVER (
            PARTITION BY hex_code
            ORDER BY recorded_at_utc, point_index
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS flight_number
    FROM flight_starts
),

flights AS (
    SELECT
        hex_code,
        flight_number,
        MIN(recorded_at_utc) AS first_airborne_time,
        MAX(recorded_at_utc) AS last_airborne_time,
        FIRST(previous_time ORDER BY recorded_at_utc, point_index)
            AS departure_ground_time,
        LAST(next_time ORDER BY recorded_at_utc, point_index)
            AS arrival_ground_time
    FROM numbered_points
    WHERE flight_state = 'airborne_candidate'
    GROUP BY hex_code, flight_number
),

endpoints AS (
    SELECT
        hex_code,
        flight_number,
        'departure' AS endpoint,
        first_airborne_time AS airborne_time,
        departure_ground_time AS ground_time
    FROM flights

    UNION ALL

    SELECT
        hex_code,
        flight_number,
        'arrival' AS endpoint,
        last_airborne_time AS airborne_time,
        arrival_ground_time AS ground_time
    FROM flights
)

SELECT
    e.hex_code,
    e.flight_number,
    e.endpoint,
    e.airborne_time,
    airport.name AS airport_name,
    ROUND(airport.distance_km, 2) AS distance_km
FROM endpoints AS e

LEFT JOIN stg_adsb_positions AS p
    ON p.hex_code = e.hex_code
   AND p.recorded_at_utc = e.ground_time
   AND p.altitude_raw = 'ground'
   AND ABS(
       EXTRACT(EPOCH FROM (e.airborne_time - p.recorded_at_utc))
   ) <= 120

LEFT JOIN LATERAL (
    SELECT
        a.name,
        6371 * ACOS(
            LEAST(1.0, GREATEST(-1.0,
                SIN(RADIANS(p.latitude))
                * SIN(RADIANS(a.latitude_deg))
                + COS(RADIANS(p.latitude))
                * COS(RADIANS(a.latitude_deg))
                * COS(RADIANS(a.longitude_deg - p.longitude))
            ))
        ) AS distance_km
    FROM raw_airports AS a
    WHERE a.type IN (
        'small_airport', 'medium_airport', 'large_airport'
    )
      AND p.latitude IS NOT NULL
      AND p.longitude IS NOT NULL
    ORDER BY distance_km, a.ident
    LIMIT 1
) AS airport
    ON airport.distance_km <= 5

ORDER BY e.hex_code, e.flight_number, e.airborne_time, e.endpoint;



SELECT
    hex_code,
    flight_number,
    MAX(CASE
        WHEN endpoint = 'departure' THEN airport_name
    END) AS departure_airport,
    MAX(CASE
        WHEN endpoint = 'arrival' THEN airport_name
    END) AS arrival_airport,
    MAX(CASE
        WHEN endpoint = 'departure' THEN airborne_time
    END) AS first_airborne_time,
    MAX(CASE
        WHEN endpoint = 'arrival' THEN airborne_time
    END) AS last_airborne_time
FROM int_flight_airport_matches
GROUP BY hex_code, flight_number
ORDER BY hex_code, flight_number;





CREATE OR REPLACE VIEW int_flights AS
WITH flights AS (
    SELECT
        hex_code,
        flight_number,
        MAX(CASE
            WHEN endpoint = 'departure' THEN airport_name
        END) AS departure_airport,
        MAX(CASE
            WHEN endpoint = 'arrival' THEN airport_name
        END) AS arrival_airport,
        MAX(CASE
            WHEN endpoint = 'departure' THEN airborne_time
        END) AS first_airborne_time,
        MAX(CASE
            WHEN endpoint = 'arrival' THEN airborne_time
        END) AS last_airborne_time
    FROM int_flight_airport_matches
    GROUP BY hex_code, flight_number
)

SELECT
    f.*,
    ROUND(
        EXTRACT(EPOCH FROM (
            last_airborne_time - first_airborne_time
        )) / 60.0,
        2
    ) AS recorded_span_minutes,

    EXISTS (
        SELECT 1
        FROM int_adsb_flight_points AS p
        WHERE p.hex_code = f.hex_code
          AND p.recorded_at_utc > f.first_airborne_time
          AND p.recorded_at_utc <= f.last_airborne_time
          AND p.gap_seconds > 120
          AND TRY_CAST(p.previous_altitude AS DOUBLE) IS NOT NULL
    ) AS has_internal_gap,

    CASE
        WHEN departure_airport IS NOT NULL
         AND arrival_airport IS NOT NULL THEN 'Both'
        WHEN departure_airport IS NOT NULL THEN 'Departure only'
        WHEN arrival_airport IS NOT NULL THEN 'Arrival only'
        ELSE 'Neither'
    END AS airports_identified

FROM flights AS f;




......
COPY (
    SELECT
        p.hex_code,
        f.flight_number,
        p.recorded_at_utc,
        p.latitude,
        p.longitude,
        p.altitude_raw,
        p.gap_seconds,
        p.is_stale
    FROM int_adsb_flight_points AS p
    JOIN int_flights AS f
        ON p.hex_code = f.hex_code
       AND p.recorded_at_utc BETWEEN
           f.first_airborne_time AND f.last_airborne_time
    ORDER BY
        p.hex_code,
        f.flight_number,
        p.recorded_at_utc,
        p.point_index
)
TO '/Users/nahidaqueen/Desktop/aviation_project/flight_points.csv'
(HEADER, DELIMITER ',');



WITH fleet_rows AS (
    SELECT
        regexp_replace(
            UPPER(TRIM("Registration No.")),
            '^N',
            ''
        ) AS registration_key,
        "Aircraft M/M/S" AS aircraft_model
    FROM raw_faa_fleet
    WHERE TRIM("DSGN") = '3EJA'
),
fleet AS (
    SELECT
        registration_key,
        COUNT(*) AS fleet_row_count,
        STRING_AGG(
            DISTINCT aircraft_model,
            '; '
        ) AS aircraft_models
    FROM fleet_rows
    GROUP BY registration_key
),
registry AS (
    SELECT
        UPPER(TRIM("N-NUMBER")) AS registration_key,
        COUNT(*) AS registry_row_count,
        COUNT(DISTINCT NULLIF(
            LOWER(TRIM("MODE S CODE HEX")),
            ''
        )) AS distinct_hex_count,
        STRING_AGG(
            DISTINCT NULLIF(
                LOWER(TRIM("MODE S CODE HEX")),
                ''
            ),
            '; '
        ) AS hex_codes
    FROM raw_faa_registry
    GROUP BY UPPER(TRIM("N-NUMBER"))
)
SELECT
    f.registration_key,
    f.aircraft_models,
    f.fleet_row_count,
    COALESCE(r.registry_row_count, 0) AS registry_row_count,
    COALESCE(r.distinct_hex_count, 0) AS distinct_hex_count,
    r.hex_codes,
    CASE
        WHEN f.registration_key IS NULL
          OR f.registration_key = ''
            THEN 'Missing registration'
        WHEN r.registry_row_count IS NULL
            THEN 'No registry match'
        WHEN r.registry_row_count > 1
            THEN 'Multiple registry rows: review'
        WHEN r.distinct_hex_count = 0
            THEN 'Missing hex code'
        WHEN NOT regexp_full_match(r.hex_codes, '[0-9a-f]{6}')
            THEN 'Invalid hex code'
        ELSE 'Ready'
    END AS lookup_status
FROM fleet AS f
LEFT JOIN registry AS r
    ON f.registration_key = r.registration_key
ORDER BY lookup_status, f.registration_key;





SET threads = 1;
SET preserve_insertion_order = false;

CREATE OR REPLACE TABLE raw_adsb_fleet_traces AS
SELECT
    downloads.source_filename,
    downloads.hex_code,
    TRY_CAST(
        json_extract_string(raw.json, '$.timestamp')
        AS DOUBLE
    ) AS reference_seconds,
    CAST(json_extract(raw.json, '$.trace') AS JSON[]) AS trace_points
FROM read_json_objects(
    '/Users/nahidaqueen/Desktop/aviation_project/tracking/2026-10-02_*.json',
    format = 'unstructured',
    filename = true
) AS raw
JOIN read_csv(
    '/Users/nahidaqueen/Desktop/aviation_project/download_report.csv',
    header = true,
    all_varchar = true
) AS downloads
    ON raw.filename LIKE '%/' || downloads.source_filename
    AND LOWER(json_extract_string(raw.json, '$.icao'))
        = downloads.hex_code
WHERE downloads.status IN ('downloaded', 'reused');


CREATE OR REPLACE TABLE stg_adsb_positions_fleet AS
WITH expanded_points AS (
    SELECT
        source_filename,
        hex_code,
        reference_seconds,
        UNNEST(trace_points) AS point,
        GENERATE_SUBSCRIPTS(trace_points, 1) - 1 AS point_index
    FROM raw_adsb_fleet_traces
),
parsed_points AS (
    SELECT
        source_filename,
        hex_code,
        point_index,
        reference_seconds,
        TRY_CAST(point ->> '$[0]' AS DOUBLE) AS offset_seconds,
        TRY_CAST(point ->> '$[1]' AS DOUBLE) AS latitude,
        TRY_CAST(point ->> '$[2]' AS DOUBLE) AS longitude,
        point ->> '$[3]' AS altitude_raw,
        TRY_CAST(point ->> '$[4]' AS DOUBLE) AS ground_speed_knots,
        TRY_CAST(point ->> '$[6]' AS INTEGER) AS flags
    FROM expanded_points
)
SELECT
    source_filename,
    hex_code,
    point_index,
    to_timestamp(reference_seconds + offset_seconds)
        AT TIME ZONE 'UTC' AS recorded_at_utc,
    latitude,
    longitude,
    altitude_raw,
    ground_speed_knots,
    flags,
    (flags & 1) = 1 AS is_stale,
    (flags & 2) = 2 AS is_new_leg_hint,
    (flags & 8) = 8 AS altitude_is_geometric
FROM parsed_points;


SELECT
    COUNT(*) AS tracking_positions,
    COUNT(DISTINCT hex_code) AS tracked_aircraft,
    COUNT(DISTINCT source_filename) AS source_files
FROM stg_adsb_positions_fleet;





WITH checked_positions AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY
                hex_code,
                recorded_at_utc,
                latitude,
                longitude,
                altitude_raw,
                ground_speed_knots,
                flags
            ORDER BY source_filename, point_index
        ) AS duplicate_number,
        EXTRACT(EPOCH FROM (
            recorded_at_utc
            - LAG(recorded_at_utc) OVER (
                PARTITION BY hex_code
                ORDER BY recorded_at_utc, source_filename, point_index
            )
        )) AS gap_seconds
    FROM stg_adsb_positions_fleet
)
SELECT
    hex_code,
    COUNT(*) AS total_positions,
    COUNT(*) FILTER (
        WHERE latitude IS NULL OR longitude IS NULL
    ) AS missing_coordinates,
    COUNT(*) FILTER (
        WHERE NOT isfinite(latitude)
           OR NOT isfinite(longitude)
           OR latitude NOT BETWEEN -90 AND 90
           OR longitude NOT BETWEEN -180 AND 180
    ) AS invalid_coordinates,
    COUNT(*) FILTER (
        WHERE recorded_at_utc IS NULL
    ) AS missing_timestamps,
    COUNT(*) FILTER (
        WHERE is_stale = true
    ) AS stale_positions,
    COUNT(*) FILTER (
        WHERE duplicate_number > 1
    ) AS duplicate_positions,
    COUNT(*) FILTER (
        WHERE gap_seconds > 120
    ) AS gaps_over_120_seconds,
    ROUND(MAX(gap_seconds), 1) AS longest_gap_seconds
FROM checked_positions
GROUP BY hex_code
ORDER BY hex_code;


WITH checked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY
                hex_code,
                recorded_at_utc,
                latitude,
                longitude,
                altitude_raw,
                ground_speed_knots,
                flags
            ORDER BY source_filename, point_index
        ) AS duplicate_number,
        LAG(recorded_at_utc) OVER (
            PARTITION BY source_filename, hex_code
            ORDER BY point_index
        ) AS previous_source_time
    FROM stg_adsb_positions_fleet
)
SELECT
    COUNT(*) AS total_positions,
    COUNT(*) FILTER (
        WHERE latitude IS NULL OR longitude IS NULL
    ) AS missing_coordinates,
    COUNT(*) FILTER (
        WHERE NOT isfinite(latitude)
           OR NOT isfinite(longitude)
           OR latitude NOT BETWEEN -90 AND 90
           OR longitude NOT BETWEEN -180 AND 180
    ) AS invalid_coordinates,
    COUNT(*) FILTER (
        WHERE recorded_at_utc IS NULL
    ) AS missing_timestamps,
    COUNT(*) FILTER (
        WHERE is_stale = true
    ) AS stale_positions,
    COUNT(*) FILTER (
        WHERE duplicate_number > 1
    ) AS duplicate_positions,
    COUNT(*) FILTER (
        WHERE recorded_at_utc < previous_source_time
    ) AS out_of_order_positions
FROM checked;


CREATE OR REPLACE VIEW int_adsb_position_audit AS
WITH numbered AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY
                hex_code,
                recorded_at_utc,
                latitude,
                longitude,
                altitude_raw,
                ground_speed_knots,
                flags
            ORDER BY source_filename, point_index
        ) AS duplicate_number
    FROM stg_adsb_positions_fleet
)
SELECT
    *,
    CASE
        WHEN recorded_at_utc IS NULL
            THEN 'Missing timestamp'
        WHEN latitude IS NULL OR longitude IS NULL
            THEN 'Missing coordinates'
        WHEN NOT isfinite(latitude)
          OR NOT isfinite(longitude)
          OR latitude NOT BETWEEN -90 AND 90
          OR longitude NOT BETWEEN -180 AND 180
            THEN 'Invalid coordinates'
        WHEN is_stale = true
            THEN 'Stale position'
        WHEN duplicate_number > 1
            THEN 'Duplicate position'
        ELSE NULL
    END AS exclusion_reason
FROM numbered;



CREATE OR REPLACE VIEW int_adsb_positions_clean AS
SELECT * EXCLUDE (duplicate_number, exclusion_reason)
FROM int_adsb_position_audit
WHERE exclusion_reason IS NULL;

SELECT
    COALESCE(exclusion_reason, 'Kept') AS cleaning_outcome,
    COUNT(*) AS positions
FROM int_adsb_position_audit
GROUP BY exclusion_reason
ORDER BY cleaning_outcome;






CREATE OR REPLACE VIEW int_adsb_fleet_flight_points AS
WITH labelled_positions AS (
    SELECT
        *,
        CASE
            WHEN altitude_raw = 'ground'
                THEN 'reported_ground'
            WHEN isfinite(TRY_CAST(altitude_raw AS DOUBLE))
                THEN 'airborne_candidate'
            ELSE 'unknown'
        END AS flight_state
    FROM int_adsb_positions_clean
)
SELECT
    *,
    LAG(flight_state) OVER aircraft_order AS previous_state,
    LEAD(flight_state) OVER aircraft_order AS next_state,
    LAG(recorded_at_utc) OVER aircraft_order AS previous_time,
    LEAD(recorded_at_utc) OVER aircraft_order AS next_time,
    EXTRACT(EPOCH FROM (
        recorded_at_utc
        - LAG(recorded_at_utc) OVER aircraft_order
    )) AS gap_seconds
FROM labelled_positions
WINDOW aircraft_order AS (
    PARTITION BY hex_code
    ORDER BY recorded_at_utc, source_filename, point_index
);


SELECT
    flight_state,
    COUNT(*) AS positions,
    COUNT(DISTINCT hex_code) AS aircraft
FROM int_adsb_fleet_flight_points
GROUP BY flight_state
ORDER BY flight_state;



CREATE OR REPLACE VIEW int_adsb_fleet_numbered_points AS
WITH starts AS (
    SELECT
        *,
        CASE
            WHEN flight_state = 'airborne_candidate'
             AND (
                 previous_state = 'reported_ground'
                 OR previous_state IS NULL
             )
                THEN 1
            ELSE 0
        END AS starts_new_interval
    FROM int_adsb_fleet_flight_points
)
SELECT
    *,
    SUM(starts_new_interval) OVER (
        PARTITION BY hex_code
        ORDER BY recorded_at_utc, source_filename, point_index
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS flight_number
FROM starts;





CREATE OR REPLACE VIEW int_adsb_fleet_flights AS
SELECT
    hex_code,
    flight_number,
    MIN(recorded_at_utc) AS first_airborne_time,
    MAX(recorded_at_utc) AS last_airborne_time,
    COUNT(*) AS airborne_positions,

    FIRST(source_filename ORDER BY
        recorded_at_utc, source_filename, point_index
    ) AS first_source_filename,

    FIRST(point_index ORDER BY
        recorded_at_utc, source_filename, point_index
    ) AS first_point_index,

    LAST(source_filename ORDER BY
        recorded_at_utc, source_filename, point_index
    ) AS last_source_filename,

    LAST(point_index ORDER BY
        recorded_at_utc, source_filename, point_index
    ) AS last_point_index,

    (
        FIRST(previous_state ORDER BY
            recorded_at_utc, source_filename, point_index
        ) IS DISTINCT FROM 'reported_ground'
        OR COALESCE(
            FIRST(gap_seconds ORDER BY
                recorded_at_utc, source_filename, point_index
            ) > 120,
            true
        )
    ) AS missing_departure,

    (
        LAST(next_state ORDER BY
            recorded_at_utc, source_filename, point_index
        ) IS DISTINCT FROM 'reported_ground'
        OR COALESCE(
            EXTRACT(EPOCH FROM (
                LAST(next_time ORDER BY
                    recorded_at_utc, source_filename, point_index
                ) - MAX(recorded_at_utc)
            )) > 120,
            true
        )
    ) AS missing_arrival,

    BOOL_OR(
        COALESCE(
            previous_state = 'airborne_candidate'
            AND gap_seconds > 120,
            false
        )
    ) AS has_internal_gap,

    COUNT(*) FILTER (
        WHERE is_new_leg_hint = true
    ) AS new_leg_hint_points,

    'Not reviewed' AS review_status

FROM int_adsb_fleet_numbered_points
WHERE flight_state = 'airborne_candidate'
GROUP BY hex_code, flight_number;




SELECT
    hex_code,
    flight_number,
    first_airborne_time,
    last_airborne_time,
    airborne_positions,
    missing_departure,
    missing_arrival,
    has_internal_gap,
    new_leg_hint_points
FROM int_adsb_fleet_flights
ORDER BY hex_code, flight_number;



SELECT
    COUNT(*) AS provisional_intervals,
    COUNT(DISTINCT hex_code) AS aircraft_with_intervals,
    SUM(airborne_positions) AS included_airborne_positions,
    COUNT(*) FILTER (
        WHERE missing_departure
    ) AS intervals_missing_departure,
    COUNT(*) FILTER (
        WHERE missing_arrival
    ) AS intervals_missing_arrival,
    COUNT(*) FILTER (
        WHERE has_internal_gap
    ) AS intervals_with_internal_gaps,
    COUNT(*) FILTER (
        WHERE airborne_positions = 1
    ) AS single_position_intervals,
    ROUND(
        MAX(EXTRACT(EPOCH FROM (
            last_airborne_time - first_airborne_time
        ))) / 60.0,
        2
    ) AS longest_observed_span_minutes
FROM int_adsb_fleet_flights;




SELECT
    COUNT(*) AS provisional_intervals,
    COUNT(DISTINCT hex_code) AS aircraft_with_intervals,
    SUM(airborne_positions) AS included_airborne_positions,
    COUNT(*) FILTER (
        WHERE missing_departure
    ) AS intervals_missing_departure,
    COUNT(*) FILTER (
        WHERE missing_arrival
    ) AS intervals_missing_arrival,
    COUNT(*) FILTER (
        WHERE has_internal_gap
    ) AS intervals_with_internal_gaps,
    COUNT(*) FILTER (
        WHERE airborne_positions = 1
    ) AS single_position_intervals,
    ROUND(
        MAX(EXTRACT(EPOCH FROM (
            last_airborne_time - first_airborne_time
        ))) / 60.0,
        2
    ) AS longest_observed_span_minutes
FROM int_adsb_fleet_flights;







SELECT
    f.hex_code,
    f.flight_number,
    'Check previous day' AS boundary_check,
    DATE '2026-10-01' AS adjacent_date,
    f.first_airborne_time AS endpoint_time_utc
FROM int_adsb_fleet_flights AS f
JOIN int_adsb_fleet_flight_points AS p
    ON p.hex_code = f.hex_code
    AND p.source_filename = f.first_source_filename
    AND p.point_index = f.first_point_index
WHERE f.missing_departure
    AND p.previous_time IS NULL

UNION ALL

SELECT
    f.hex_code,
    f.flight_number,
    'Check next day' AS boundary_check,
    DATE '2026-10-03' AS adjacent_date,
    f.last_airborne_time AS endpoint_time_utc
FROM int_adsb_fleet_flights AS f
JOIN int_adsb_fleet_flight_points AS p
    ON p.hex_code = f.hex_code
    AND p.source_filename = f.last_source_filename
    AND p.point_index = f.last_point_index
WHERE f.missing_arrival
    AND p.next_time IS NULL

ORDER BY hex_code, adjacent_date;



SELECT
    f.hex_code,
    f.flight_number,
    'Check previous day' AS boundary_check,
    DATE '2026-10-01' AS adjacent_date,
    f.first_airborne_time AS endpoint_time_utc
FROM int_adsb_fleet_flights AS f
JOIN int_adsb_fleet_flight_points AS p
    ON p.hex_code = f.hex_code
    AND p.source_filename = f.first_source_filename
    AND p.point_index = f.first_point_index
WHERE f.missing_departure
    AND p.previous_time IS NULL

UNION ALL

SELECT
    f.hex_code,
    f.flight_number,
    'Check next day' AS boundary_check,
    DATE '2026-10-03' AS adjacent_date,
    f.last_airborne_time AS endpoint_time_utc
FROM int_adsb_fleet_flights AS f
JOIN int_adsb_fleet_flight_points AS p
    ON p.hex_code = f.hex_code
    AND p.source_filename = f.last_source_filename
    AND p.point_index = f.last_point_index
WHERE f.missing_arrival
    AND p.next_time IS NULL

ORDER BY hex_code, adjacent_date;




COPY (
    SELECT DISTINCT
        f.hex_code,
        DATE '2026-10-01' AS adjacent_date
    FROM int_adsb_fleet_flights AS f
    JOIN int_adsb_fleet_flight_points AS p
        ON p.hex_code = f.hex_code
       AND p.source_filename = f.first_source_filename
       AND p.point_index = f.first_point_index
    WHERE f.missing_departure
      AND p.previous_time IS NULL

    UNION

    SELECT DISTINCT
        f.hex_code,
        DATE '2026-10-03' AS adjacent_date
    FROM int_adsb_fleet_flights AS f
    JOIN int_adsb_fleet_flight_points AS p
        ON p.hex_code = f.hex_code
       AND p.source_filename = f.last_source_filename
       AND p.point_index = f.last_point_index
    WHERE f.missing_arrival
      AND p.next_time IS NULL

    ORDER BY hex_code, adjacent_date
)
TO '/Users/nahidaqueen/Desktop/aviation_project/boundary_requests.csv'
(FORMAT CSV, HEADER);


CREATE OR REPLACE TABLE raw_boundary_download_report AS
SELECT *
FROM read_csv(
    '/Users/nahidaqueen/Desktop/aviation_project/boundary_download_report.csv',
    header = true,
    all_varchar = true
);


SELECT
    status,
    COUNT(*) AS request_count
FROM raw_boundary_download_report
GROUP BY status
ORDER BY status;




CREATE OR REPLACE TABLE raw_adsb_boundary_traces AS
SELECT
    j.filename AS source_filename,
    LOWER(json_extract_string(j.json, '$.icao')) AS hex_code,
    CAST(r.requested_date AS DATE) AS requested_date,
    TRY_CAST(
        json_extract_string(j.json, '$.timestamp')
        AS DOUBLE
    ) AS reference_seconds,
    CAST(
        json_extract(j.json, '$.trace')
        AS JSON[]
    ) AS trace_points
FROM read_json_objects(
    [
        '/Users/nahidaqueen/Desktop/aviation_project/tracking/2026-10-01_*.json',
        '/Users/nahidaqueen/Desktop/aviation_project/tracking/2026-10-03_*.json'
    ],
    format = 'unstructured',
    filename = true
) AS j
JOIN raw_boundary_download_report AS r
    ON ends_with(j.filename, '/' || r.source_filename)
   AND LOWER(json_extract_string(j.json, '$.icao')) = r.hex_code
WHERE r.status IN ('downloaded', 'reused');


CREATE OR REPLACE TABLE stg_adsb_positions_boundary AS
WITH expanded AS (
    SELECT
        source_filename,
        hex_code,
        reference_seconds,
        UNNEST(trace_points) AS point,
        GENERATE_SUBSCRIPTS(trace_points, 1) - 1 AS point_index
    FROM raw_adsb_boundary_traces
),
parsed AS (
    SELECT
        source_filename,
        hex_code,
        point_index,
        to_timestamp(
            reference_seconds
            + TRY_CAST(json_extract_string(point, '$[0]') AS DOUBLE)
        ) AT TIME ZONE 'UTC' AS recorded_at_utc,
        TRY_CAST(json_extract_string(point, '$[1]') AS DOUBLE)
            AS latitude,
        TRY_CAST(json_extract_string(point, '$[2]') AS DOUBLE)
            AS longitude,
        json_extract_string(point, '$[3]') AS altitude_raw,
        TRY_CAST(json_extract_string(point, '$[4]') AS DOUBLE)
            AS ground_speed_knots,
        TRY_CAST(json_extract_string(point, '$[6]') AS BIGINT)
            AS flags
    FROM expanded
)
SELECT
    *,
    (flags & 1) != 0 AS is_stale,
    (flags & 2) != 0 AS is_new_leg_hint,
    (flags & 8) != 0 AS altitude_is_geometric
FROM parsed;







WITH checked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY
                hex_code,
                recorded_at_utc,
                latitude,
                longitude,
                altitude_raw,
                ground_speed_knots,
                flags
            ORDER BY source_filename, point_index
        ) AS duplicate_number
    FROM stg_adsb_positions_boundary
)
SELECT
    COUNT(*) AS total_positions,
    COUNT(DISTINCT source_filename) AS loaded_files,
    COUNT(*) FILTER (
        WHERE recorded_at_utc IS NULL
    ) AS missing_timestamps,
    COUNT(*) FILTER (
        WHERE latitude IS NULL OR longitude IS NULL
    ) AS missing_coordinates,
    COUNT(*) FILTER (
        WHERE NOT isfinite(latitude)
           OR NOT isfinite(longitude)
           OR latitude NOT BETWEEN -90 AND 90
           OR longitude NOT BETWEEN -180 AND 180
    ) AS invalid_coordinates,
    COUNT(*) FILTER (
        WHERE is_stale = true
    ) AS stale_positions,
    COUNT(*) FILTER (
        WHERE duplicate_number > 1
    ) AS duplicate_positions
FROM checked;




CREATE OR REPLACE VIEW int_adsb_combined_position_audit AS
WITH combined AS (
    SELECT *
    FROM stg_adsb_positions_fleet

    UNION ALL BY NAME

    SELECT *
    FROM stg_adsb_positions_boundary
),
numbered AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY
                hex_code,
                recorded_at_utc,
                latitude,
                longitude,
                altitude_raw,
                ground_speed_knots,
                flags
            ORDER BY source_filename, point_index
        ) AS duplicate_number
    FROM combined
)
SELECT
    *,
    CASE
        WHEN recorded_at_utc IS NULL
            THEN 'Missing timestamp'
        WHEN latitude IS NULL OR longitude IS NULL
            THEN 'Missing coordinates'
        WHEN NOT isfinite(latitude)
          OR NOT isfinite(longitude)
          OR latitude NOT BETWEEN -90 AND 90
          OR longitude NOT BETWEEN -180 AND 180
            THEN 'Invalid coordinates'
        WHEN is_stale = true
            THEN 'Stale position'
        WHEN duplicate_number > 1
            THEN 'Duplicate position'
        ELSE NULL
    END AS exclusion_reason
FROM numbered;




CREATE OR REPLACE VIEW int_adsb_combined_positions_clean AS
SELECT * EXCLUDE (duplicate_number, exclusion_reason)
FROM int_adsb_combined_position_audit
WHERE exclusion_reason IS NULL;


SELECT
    COALESCE(exclusion_reason, 'Kept') AS outcome,
    COUNT(*) AS position_count
FROM int_adsb_combined_position_audit
GROUP BY exclusion_reason
ORDER BY outcome;


CREATE OR REPLACE TABLE int_adsb_combined_flight_points AS
WITH labelled AS (
    SELECT
        *,
        CASE
            WHEN altitude_raw = 'ground'
                THEN 'reported_ground'
            WHEN isfinite(TRY_CAST(altitude_raw AS DOUBLE))
                THEN 'airborne_candidate'
            ELSE 'unknown'
        END AS flight_state
    FROM int_adsb_combined_positions_clean
),
neighbours AS (
    SELECT
        *,
        LAG(flight_state) OVER aircraft_order AS previous_state,
        LEAD(flight_state) OVER aircraft_order AS next_state,
        LAG(recorded_at_utc) OVER aircraft_order AS previous_time,
        LEAD(recorded_at_utc) OVER aircraft_order AS next_time
    FROM labelled
    WINDOW aircraft_order AS (
        PARTITION BY hex_code
        ORDER BY recorded_at_utc, source_filename, point_index
    )
),
starts AS (
    SELECT
        *,
        EXTRACT(EPOCH FROM (
            recorded_at_utc - previous_time
        )) AS gap_seconds,
        CASE
            WHEN flight_state = 'airborne_candidate'
             AND (
                 previous_state IS NULL
                 OR previous_state <> 'airborne_candidate'
             )
                THEN 1
            ELSE 0
        END AS starts_new_interval
    FROM neighbours
)
SELECT
    *,
    SUM(starts_new_interval) OVER (
        PARTITION BY hex_code
        ORDER BY recorded_at_utc, source_filename, point_index
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS flight_number
FROM starts;


SELECT
    COALESCE(exclusion_reason, 'Kept') AS outcome,
    COUNT(*) AS position_count
FROM int_adsb_combined_position_audit
GROUP BY exclusion_reason
ORDER BY outcome;



CREATE OR REPLACE TABLE int_adsb_combined_flights AS
WITH airborne AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY hex_code, flight_number
            ORDER BY recorded_at_utc, source_filename, point_index
        ) AS first_rank,
        ROW_NUMBER() OVER (
            PARTITION BY hex_code, flight_number
            ORDER BY recorded_at_utc DESC,
                     source_filename DESC,
                     point_index DESC
        ) AS last_rank
    FROM int_adsb_combined_flight_points
    WHERE flight_state = 'airborne_candidate'
)
SELECT
    hex_code,
    flight_number,
    MIN(recorded_at_utc) AS first_airborne_time,
    MAX(recorded_at_utc) AS last_airborne_time,
    COUNT(*) AS airborne_positions,
    COUNT(*) FILTER (
        WHERE recorded_at_utc >= TIMESTAMP '2026-10-02 00:00:00'
          AND recorded_at_utc < TIMESTAMP '2026-10-03 00:00:00'
    ) AS analysis_day_positions,

    MAX(source_filename) FILTER (
        WHERE first_rank = 1
    ) AS first_source_filename,
    MAX(point_index) FILTER (
        WHERE first_rank = 1
    ) AS first_point_index,
    MAX(source_filename) FILTER (
        WHERE last_rank = 1
    ) AS last_source_filename,
    MAX(point_index) FILTER (
        WHERE last_rank = 1
    ) AS last_point_index,

    BOOL_OR(
        previous_state IS DISTINCT FROM 'reported_ground'
        OR COALESCE(gap_seconds > 120, true)
    ) FILTER (WHERE first_rank = 1) AS missing_departure,

    BOOL_OR(
        next_state IS DISTINCT FROM 'reported_ground'
        OR COALESCE(
            EXTRACT(EPOCH FROM (
                next_time - recorded_at_utc
            )) > 120,
            true
        )
    ) FILTER (WHERE last_rank = 1) AS missing_arrival,

    BOOL_OR(
        COALESCE(
            previous_state = 'airborne_candidate'
            AND gap_seconds > 120,
            false
        )
    ) AS has_internal_gap,

    MAX(gap_seconds) FILTER (
        WHERE previous_state = 'airborne_candidate'
    ) AS longest_internal_gap_seconds,

    MIN(recorded_at_utc) < TIMESTAMP '2026-10-02 00:00:00'
        AS extends_before_analysis_day,
    MAX(recorded_at_utc) >= TIMESTAMP '2026-10-03 00:00:00'
        AS extends_after_analysis_day,

    'Not reviewed' AS review_status
FROM airborne
GROUP BY hex_code, flight_number
HAVING COUNT(*) FILTER (
    WHERE recorded_at_utc >= TIMESTAMP '2026-10-02 00:00:00'
      AND recorded_at_utc < TIMESTAMP '2026-10-03 00:00:00'
) > 0;


SELECT
    COUNT(*) AS provisional_intervals,
    COUNT(DISTINCT hex_code) AS aircraft,
    COUNT(*) FILTER (WHERE missing_departure) AS missing_departures,
    COUNT(*) FILTER (WHERE missing_arrival) AS missing_arrivals,
    COUNT(*) FILTER (WHERE has_internal_gap) AS intervals_with_gaps,
    COUNT(*) FILTER (
        WHERE extends_before_analysis_day
           OR extends_after_analysis_day
    ) AS intervals_with_adjacent_day_observations
FROM int_adsb_combined_flights;




DESCRIBE raw_airports;


CREATE OR REPLACE TABLE int_fleet_endpoint_airports AS
WITH endpoints AS (
    SELECT
        hex_code,
        flight_number,
        'departure' AS endpoint_type,
        first_airborne_time AS airborne_time,
        first_source_filename AS airborne_source,
        first_point_index AS airborne_index,
        missing_departure AS missing_endpoint
    FROM int_adsb_combined_flights

    UNION ALL

    SELECT
        hex_code,
        flight_number,
        'arrival' AS endpoint_type,
        last_airborne_time AS airborne_time,
        last_source_filename AS airborne_source,
        last_point_index AS airborne_index,
        missing_arrival AS missing_endpoint
    FROM int_adsb_combined_flights
),
ground_evidence AS (
    SELECT
        e.*,
        g.recorded_at_utc AS ground_time,
        g.latitude AS ground_latitude,
        g.longitude AS ground_longitude,
        g.source_filename AS ground_source_filename,
        g.point_index AS ground_point_index,
        ABS(EXTRACT(EPOCH FROM (
            e.airborne_time - g.recorded_at_utc
        ))) AS ground_time_difference_seconds
    FROM endpoints AS e
    JOIN int_adsb_combined_flight_points AS p
        ON p.hex_code = e.hex_code
       AND p.source_filename = e.airborne_source
       AND p.point_index = e.airborne_index
    LEFT JOIN LATERAL (
        SELECT g.*
        FROM int_adsb_combined_positions_clean AS g
        WHERE NOT e.missing_endpoint
          AND g.hex_code = e.hex_code
          AND g.altitude_raw = 'ground'
          AND g.recorded_at_utc = CASE
              WHEN e.endpoint_type = 'departure'
                  THEN p.previous_time
              ELSE p.next_time
          END
        ORDER BY g.source_filename, g.point_index
        LIMIT 1
    ) AS g ON true
)
SELECT
    e.*,
    a.ident AS nearest_airport_ident,
    a.distance_km AS nearest_airport_distance_km,
    CASE WHEN a.distance_km <= 5
        THEN a.ident END AS matched_airport_ident,
    CASE WHEN a.distance_km <= 5
        THEN a.name END AS matched_airport_name,
    CASE WHEN a.distance_km <= 5
        THEN a.latitude_deg END AS airport_latitude,
    CASE WHEN a.distance_km <= 5
        THEN a.longitude_deg END AS airport_longitude,
    CASE
        WHEN e.ground_time IS NULL
            THEN 'No suitable ground observation'
        WHEN a.ident IS NULL
            THEN 'No eligible airport'
        WHEN a.distance_km > 5
            THEN 'Nearest airport beyond 5 km'
        ELSE 'Matched'
    END AS match_status
FROM ground_evidence AS e
LEFT JOIN LATERAL (
    SELECT
        a.ident,
        a.name,
        a.latitude_deg,
        a.longitude_deg,
        2 * 6371 * ASIN(SQRT(
            LEAST(1.0, GREATEST(0.0,
                POWER(SIN(RADIANS(
                    a.latitude_deg - e.ground_latitude
                ) / 2), 2)
                + COS(RADIANS(e.ground_latitude))
                * COS(RADIANS(a.latitude_deg))
                * POWER(SIN(RADIANS(
                    a.longitude_deg - e.ground_longitude
                ) / 2), 2)
            ))
        )) AS distance_km
    FROM raw_airports AS a
    WHERE e.ground_time IS NOT NULL
      AND a.ident IS NOT NULL
      AND a.type IN (
          'small_airport', 'medium_airport', 'large_airport'
      )
      AND isfinite(a.latitude_deg)
      AND isfinite(a.longitude_deg)
      AND a.latitude_deg BETWEEN -90 AND 90
      AND a.longitude_deg BETWEEN -180 AND 180
    ORDER BY distance_km, a.ident
    LIMIT 1
) AS a ON true;



......

CREATE OR REPLACE VIEW int_fleet_flight_airports AS
SELECT
    f.*,

    d.matched_airport_ident AS departure_airport,
    d.matched_airport_name AS departure_airport_name,
    d.airport_latitude AS departure_airport_latitude,
    d.airport_longitude AS departure_airport_longitude,
    d.nearest_airport_distance_km AS departure_distance_km,
    d.match_status AS departure_match_status,
    d.ground_time AS departure_ground_time,
    d.ground_time_difference_seconds AS departure_time_difference_seconds,
    d.ground_source_filename AS departure_ground_source,
    d.ground_point_index AS departure_ground_index,

    a.matched_airport_ident AS arrival_airport,
    a.matched_airport_name AS arrival_airport_name,
    a.airport_latitude AS arrival_airport_latitude,
    a.airport_longitude AS arrival_airport_longitude,
    a.nearest_airport_distance_km AS arrival_distance_km,
    a.match_status AS arrival_match_status,
    a.ground_time AS arrival_ground_time,
    a.ground_time_difference_seconds AS arrival_time_difference_seconds,
    a.ground_source_filename AS arrival_ground_source,
    a.ground_point_index AS arrival_ground_index,

    (
        d.matched_airport_ident IS NOT NULL
        AND a.matched_airport_ident IS NOT NULL
    ) AS both_airports_matched

FROM int_adsb_combined_flights AS f
LEFT JOIN int_fleet_endpoint_airports AS d
    ON d.hex_code = f.hex_code
   AND d.flight_number = f.flight_number
   AND d.endpoint_type = 'departure'
LEFT JOIN int_fleet_endpoint_airports AS a
    ON a.hex_code = f.hex_code
   AND a.flight_number = f.flight_number
   AND a.endpoint_type = 'arrival';

SELECT
    COUNT(*) AS total_intervals,
    COUNT(*) FILTER (
        WHERE both_airports_matched
    ) AS both_airports_matched,
    COUNT(*) FILTER (
        WHERE both_airports_matched AND NOT has_internal_gap
    ) AS both_matched_without_internal_gaps,
    COUNT(*) FILTER (
        WHERE both_airports_matched AND has_internal_gap
    ) AS both_matched_with_internal_gaps
FROM int_fleet_flight_airports;





SELECT
    hex_code,
    flight_number,
    first_airborne_time,
    last_airborne_time,
    ROUND(
        EXTRACT(EPOCH FROM (
            last_airborne_time - first_airborne_time
        )) / 3600.0,
        2
    ) AS observed_span_hours,
    departure_airport,
    arrival_airport,
    missing_departure,
    missing_arrival,
    has_internal_gap,
    ROUND(
        longest_internal_gap_seconds / 60.0,
        1
    ) AS longest_internal_gap_minutes
FROM int_fleet_flight_airports
ORDER BY
    observed_span_hours DESC,
    hex_code,
    flight_number
LIMIT 10;


WITH observations AS (
    SELECT
        p.hex_code,
        p.recorded_at_utc,
        p.latitude,
        p.longitude,
        p.altitude_raw,
        p.ground_speed_knots,
        p.gap_seconds,
        p.previous_state,
        p.flight_state,
        p.source_filename,
        p.point_index
    FROM int_adsb_fleet_flight_points AS p
    JOIN int_adsb_combined_flights AS f
        ON p.hex_code = f.hex_code
       AND p.recorded_at_utc BETWEEN
           f.first_airborne_time
           AND f.last_airborne_time
    WHERE f.hex_code = 'ab80b2'
      AND f.flight_number = 1
)
SELECT *
FROM observations
WHERE gap_seconds > 120
ORDER BY gap_seconds DESC
LIMIT 15;






CREATE OR REPLACE VIEW int_adsb_fleet_numbered_points_validated AS

WITH starts AS (
    SELECT
        *,
        CASE
            WHEN flight_state = 'airborne_candidate'
             AND (
                 previous_state = 'reported_ground'
                 OR previous_state IS NULL
                 OR gap_seconds > 120
                 OR is_new_leg_hint = true
             )
            THEN 1
            ELSE 0
        END AS starts_new_interval
    FROM int_adsb_fleet_flight_points
),

numbered AS (
    SELECT
        *,
        SUM(starts_new_interval) OVER (
            PARTITION BY hex_code
            ORDER BY recorded_at_utc, source_filename, point_index
            ROWS BETWEEN UNBOUNDED PRECEDING
                     AND CURRENT ROW
        ) AS validated_interval_number
    FROM starts
)

SELECT *
FROM numbered;




SELECT
    validated_interval_number,
    MIN(recorded_at_utc) AS first_observation,
    MAX(recorded_at_utc) AS last_observation,
    COUNT(*) AS airborne_positions
FROM int_adsb_fleet_numbered_points_validated
WHERE hex_code = 'ab80b2'
  AND flight_state = 'airborne_candidate'
GROUP BY validated_interval_number
ORDER BY validated_interval_number;



SELECT
    validated_interval_number,
    MIN(recorded_at_utc) AS first_observation,
    MAX(recorded_at_utc) AS last_observation,
    COUNT(*) AS airborne_positions,
    ROUND(
        EXTRACT(EPOCH FROM (
            MAX(recorded_at_utc) - MIN(recorded_at_utc)
        )) / 60.0,
        2
    ) AS observed_span_minutes,
    ROUND(MAX(gap_seconds), 2) AS largest_gap_seconds,
    COUNT(*) FILTER (
        WHERE is_new_leg_hint = true
    ) AS new_leg_hints
FROM int_adsb_fleet_numbered_points_validated
WHERE hex_code = 'ab80b2'
  AND flight_state = 'airborne_candidate'
GROUP BY validated_interval_number
ORDER BY validated_interval_number;



WITH segment_positions AS (
    SELECT
        hex_code,
        validated_interval_number,
        recorded_at_utc,
        LAG(recorded_at_utc) OVER (
            PARTITION BY hex_code, validated_interval_number
            ORDER BY recorded_at_utc, source_filename, point_index
        ) AS previous_segment_time
    FROM int_adsb_fleet_numbered_points_validated
    WHERE hex_code = 'ab80b2'
      AND flight_state = 'airborne_candidate'
),
segment_gaps AS (
    SELECT
        *,
        EXTRACT(EPOCH FROM (
            recorded_at_utc - previous_segment_time
        )) AS internal_gap_seconds
    FROM segment_positions
)
SELECT
    validated_interval_number,
    COUNT(*) AS airborne_positions,
    ROUND(MAX(internal_gap_seconds), 2)
        AS largest_internal_gap_seconds,
    COUNT(*) FILTER (
        WHERE internal_gap_seconds > 120
    ) AS internal_gaps_over_120_seconds
FROM segment_gaps
GROUP BY validated_interval_number
ORDER BY validated_interval_number;




WITH segment_positions AS (
    SELECT
        hex_code,
        validated_interval_number,
        recorded_at_utc,
        LAG(recorded_at_utc) OVER (
            PARTITION BY hex_code, validated_interval_number
            ORDER BY recorded_at_utc, source_filename, point_index
        ) AS previous_segment_time
    FROM int_adsb_fleet_numbered_points_validated
    WHERE flight_state = 'airborne_candidate'
),
segment_gaps AS (
    SELECT
        *,
        EXTRACT(EPOCH FROM (
            recorded_at_utc - previous_segment_time
        )) AS internal_gap_seconds
    FROM segment_positions
)
SELECT
    COUNT(*) AS total_provisional_segments,
    COUNT(DISTINCT hex_code) AS aircraft_with_segments,
    COUNT(*) FILTER (
        WHERE largest_gap_seconds > 120
    ) AS segments_failing_gap_check,
    ROUND(MAX(largest_gap_seconds), 2)
        AS largest_internal_gap_seconds
FROM (
    SELECT
        hex_code,
        validated_interval_number,
        MAX(internal_gap_seconds) AS largest_gap_seconds
    FROM segment_gaps
    GROUP BY hex_code, validated_interval_number
) AS segments;




WITH segments AS (
    SELECT
        hex_code,
        validated_interval_number,
        MIN(recorded_at_utc) AS start_time,
        MAX(recorded_at_utc) AS end_time
    FROM int_adsb_fleet_numbered_points_validated
    WHERE flight_state = 'airborne_candidate'
    GROUP BY hex_code, validated_interval_number
),
ordered AS (
    SELECT
        *,
        MAX(end_time) OVER (
            PARTITION BY hex_code
            ORDER BY start_time, validated_interval_number
            ROWS BETWEEN UNBOUNDED PRECEDING
                     AND 1 PRECEDING
        ) AS previous_max_end
    FROM segments
)
SELECT
    COUNT(*) AS total_segments,
    COUNT(*) FILTER (
        WHERE start_time < previous_max_end
    ) AS overlapping_segments
FROM ordered;




CREATE OR REPLACE VIEW int_fleet_validated_segments AS
SELECT
    hex_code,
    validated_interval_number AS segment_number,
    MIN(recorded_at_utc) AS first_airborne_time,
    MAX(recorded_at_utc) AS last_airborne_time,
    COUNT(*) AS airborne_positions,
    ROUND(
        EXTRACT(EPOCH FROM (
            MAX(recorded_at_utc) - MIN(recorded_at_utc)
        )) / 60.0,
        2
    ) AS observed_span_minutes
FROM int_adsb_fleet_numbered_points_validated
WHERE flight_state = 'airborne_candidate'
GROUP BY hex_code, validated_interval_number;


------
CREATE OR REPLACE VIEW int_fleet_validated_endpoints AS

WITH endpoints AS (
    SELECT
        s.hex_code,
        s.segment_number,
        'departure' AS endpoint,
        s.first_airborne_time AS airborne_time
    FROM int_fleet_validated_segments AS s

    UNION ALL

    SELECT
        s.hex_code,
        s.segment_number,
        'arrival' AS endpoint,
        s.last_airborne_time AS airborne_time
    FROM int_fleet_validated_segments AS s
)

SELECT
    e.hex_code,
    e.segment_number,
    e.endpoint,
    e.airborne_time,
    p.recorded_at_utc AS ground_time,
    p.latitude,
    p.longitude,
    ABS(
        EXTRACT(EPOCH FROM (
            e.airborne_time - p.recorded_at_utc
        ))
    ) AS seconds_from_airborne

FROM endpoints AS e

LEFT JOIN LATERAL (
    SELECT
        p.recorded_at_utc,
        p.latitude,
        p.longitude
    FROM int_adsb_positions_clean AS p
    WHERE p.hex_code = e.hex_code
      AND p.altitude_raw = 'ground'
      AND (
          (
              e.endpoint = 'departure'
              AND p.recorded_at_utc <= e.airborne_time
          )
          OR
          (
              e.endpoint = 'arrival'
              AND p.recorded_at_utc >= e.airborne_time
          )
      )
      AND ABS(
          EXTRACT(EPOCH FROM (
              e.airborne_time - p.recorded_at_utc
          ))
      ) <= 120
    ORDER BY
        ABS(EXTRACT(EPOCH FROM (
            e.airborne_time - p.recorded_at_utc
        )))
    LIMIT 1
) AS p ON TRUE;


SELECT
    endpoint,
    COUNT(*) AS total_endpoints,
    COUNT(*) FILTER (
        WHERE ground_time IS NOT NULL
    ) AS observed_ground_endpoints,
    COUNT(*) FILTER (
        WHERE ground_time IS NULL
    ) AS missing_ground_endpoints
FROM int_fleet_validated_endpoints
GROUP BY endpoint;


---
CREATE OR REPLACE VIEW int_fleet_validated_airports AS

SELECT
    e.hex_code,
    e.segment_number,
    e.endpoint,
    e.airborne_time,
    e.ground_time,
    a.ident AS airport_code,
    a.name AS airport_name,
    ROUND(a.distance_km, 2) AS distance_km

FROM int_fleet_validated_endpoints AS e

LEFT JOIN LATERAL (
    SELECT
        airport.ident,
        airport.name,
        6371 * ACOS(
            LEAST(1.0, GREATEST(-1.0,
                SIN(RADIANS(e.latitude))
                * SIN(RADIANS(airport.latitude_deg))
                + COS(RADIANS(e.latitude))
                * COS(RADIANS(airport.latitude_deg))
                * COS(RADIANS(
                    airport.longitude_deg - e.longitude
                ))
            ))
        ) AS distance_km
    FROM raw_airports AS airport
    WHERE airport.type IN (
        'small_airport',
        'medium_airport',
        'large_airport'
    )
      AND e.latitude IS NOT NULL
      AND e.longitude IS NOT NULL
    ORDER BY distance_km, airport.ident
    LIMIT 1
) AS a ON a.distance_km <= 5;



SELECT
    endpoint,
    COUNT(*) AS total_endpoints,
    COUNT(*) FILTER (
        WHERE airport_name IS NOT NULL
    ) AS matched_airports,
    COUNT(*) FILTER (
        WHERE airport_name IS NULL
    ) AS unmatched_airports
FROM int_fleet_validated_airports
GROUP BY endpoint;

---

WITH airport_coverage AS (
    SELECT
        hex_code,
        segment_number,
        MAX(CASE
            WHEN endpoint = 'departure'
            THEN airport_code
        END) AS departure_airport,
        MAX(CASE
            WHEN endpoint = 'arrival'
            THEN airport_code
        END) AS arrival_airport
    FROM int_fleet_validated_airports
    GROUP BY hex_code, segment_number
),
segments AS (
    SELECT
        s.*,
        LAG(last_airborne_time) OVER (
            PARTITION BY hex_code
            ORDER BY first_airborne_time, segment_number
        ) AS previous_end
    FROM int_fleet_validated_segments AS s
),
duplicate_check AS (
    SELECT
        hex_code,
        segment_number,
        endpoint,
        COUNT(*) AS endpoint_rows
    FROM int_fleet_validated_airports
    GROUP BY hex_code, segment_number, endpoint
)
SELECT
    COUNT(*) AS total_segments,
    COUNT(*) FILTER (
        WHERE s.first_airborne_time < s.previous_end
    ) AS overlapping_segments,
    COUNT(*) FILTER (
        WHERE a.departure_airport IS NOT NULL
          AND a.arrival_airport IS NOT NULL
    ) AS both_airports_matched,
    COUNT(*) FILTER (
        WHERE a.departure_airport IS NOT NULL
          AND a.arrival_airport IS NULL
    ) AS departure_only,
    COUNT(*) FILTER (
        WHERE a.departure_airport IS NULL
          AND a.arrival_airport IS NOT NULL
    ) AS arrival_only,
    COUNT(*) FILTER (
        WHERE a.departure_airport IS NULL
          AND a.arrival_airport IS NULL
    ) AS neither_airport,
    (
        SELECT COUNT(*)
        FROM duplicate_check
        WHERE endpoint_rows > 1
    ) AS duplicate_endpoint_groups
FROM segments AS s
LEFT JOIN airport_coverage AS a
    ON s.hex_code = a.hex_code
   AND s.segment_number = a.segment_number;



----
----


CREATE OR REPLACE VIEW mart_3eja_reconstruction AS

WITH airports AS (
    SELECT
        hex_code,
        segment_number,
        MAX(airport_code) FILTER (
            WHERE endpoint = 'departure'
        ) AS departure_airport,
        MAX(airport_name) FILTER (
            WHERE endpoint = 'departure'
        ) AS departure_name,
        MAX(airport_code) FILTER (
            WHERE endpoint = 'arrival'
        ) AS arrival_airport,
        MAX(airport_name) FILTER (
            WHERE endpoint = 'arrival'
        ) AS arrival_name
    FROM int_fleet_validated_airports
    GROUP BY hex_code, segment_number
)

SELECT
    s.hex_code,
    s.segment_number,
    s.first_airborne_time,
    s.last_airborne_time,
    s.airborne_positions,
    s.observed_span_minutes,
    a.departure_airport,
    a.departure_name,
    a.arrival_airport,
    a.arrival_name,
    CASE
        WHEN a.departure_airport IS NOT NULL
         AND a.arrival_airport IS NOT NULL
            THEN 'both_airports_matched'
        WHEN a.departure_airport IS NOT NULL
            THEN 'departure_only'
        WHEN a.arrival_airport IS NOT NULL
            THEN 'arrival_only'
        ELSE 'neither_airport'
    END AS reconstruction_status
FROM int_fleet_validated_segments AS s
LEFT JOIN airports AS a
    ON s.hex_code = a.hex_code
   AND s.segment_number = a.segment_number;



SELECT
    reconstruction_status,
    COUNT(*) AS segments
FROM mart_3eja_reconstruction
GROUP BY reconstruction_status
ORDER BY segments DESC;





------------

SELECT
    departure_airport,
    departure_name,
    arrival_airport,
    arrival_name,
    COUNT(*) AS observed_segments,
    COUNT(DISTINCT hex_code) AS aircraft_count
FROM mart_3eja_reconstruction
WHERE reconstruction_status = 'both_airports_matched'
GROUP BY
    departure_airport,
    departure_name,
    arrival_airport,
    arrival_name
ORDER BY observed_segments DESC,

SELECT *
FROM mart_3eja_reconstruction;
         departure_airport,
         arrival_airport;

