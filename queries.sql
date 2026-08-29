-- =====================================================================
-- Spotify Analytics — Advanced SQL Project
-- Target: MySQL 8.0+  (window functions and CTEs require 8.0)
--
-- The `spotify` table is created by the loader in the notebook.
-- This file contains the analysis queries only.
-- =====================================================================


-- ---------------------------------------------------------------------
-- DATA QUALITY
-- ---------------------------------------------------------------------

-- Audit: impossible values and malformed boolean flags.
SELECT
    COUNT(*)                    AS total_rows,
    COUNT(DISTINCT track)       AS distinct_tracks,
    COUNT(DISTINCT artist)      AS distinct_artists,
    SUM(duration_min = 0)       AS zero_duration_tracks,
    SUM(licensed IS NULL)       AS null_licensed_flag,
    SUM(official_video IS NULL) AS null_official_video_flag
FROM spotify;

-- Two tracks report zero duration while carrying real engagement metrics.
-- A track cannot be zero minutes long, so these rows are corrupt.
DELETE FROM spotify WHERE duration_min = 0;


-- ---------------------------------------------------------------------
-- EASY
-- ---------------------------------------------------------------------

-- Q1. Tracks with more than 1 billion streams.
SELECT track, artist, stream
FROM spotify
WHERE stream > 1000000000
ORDER BY stream DESC;


-- Q2. All albums with their respective artists.
SELECT DISTINCT album, artist
FROM spotify
ORDER BY album;


-- Q3. Total comments on licensed tracks.
-- The 469 malformed flags are stored as NULL, so `= TRUE` excludes them
-- automatically rather than miscounting them as licensed.
SELECT
    COUNT(*)             AS licensed_tracks,
    SUM(comments)        AS total_comments,
    ROUND(AVG(comments)) AS avg_comments_per_track
FROM spotify
WHERE licensed = TRUE;


-- Q4. Tracks belonging to album type 'single'.
SELECT track, artist, album
FROM spotify
WHERE album_type = 'single';


-- Q5. Track count per artist.
SELECT artist, COUNT(*) AS total_tracks
FROM spotify
GROUP BY artist
ORDER BY total_tracks DESC;


-- ---------------------------------------------------------------------
-- MEDIUM
-- ---------------------------------------------------------------------

-- Q6. Average danceability per album.
-- HAVING requires >= 3 tracks so a single-song album cannot top the list.
SELECT
    album,
    COUNT(*)                    AS track_count,
    ROUND(AVG(danceability), 3) AS avg_danceability
FROM spotify
GROUP BY album
HAVING COUNT(*) >= 3
ORDER BY avg_danceability DESC;


-- Q7. Top 5 tracks by energy.
SELECT track, artist, MAX(energy) AS max_energy
FROM spotify
GROUP BY track, artist
ORDER BY max_energy DESC
LIMIT 5;


-- Q8. Views and likes for tracks with an official video.
-- NULLIF guards the division against zero-view tracks.
SELECT
    track,
    SUM(views) AS total_views,
    SUM(likes) AS total_likes,
    ROUND(100.0 * SUM(likes) / NULLIF(SUM(views), 0), 2) AS like_rate_pct
FROM spotify
WHERE official_video = TRUE
GROUP BY track
ORDER BY total_views DESC;


-- Q9. Total views per track within each album.
SELECT
    album,
    track,
    SUM(views) AS total_views
FROM spotify
GROUP BY album, track
ORDER BY total_views DESC;


-- Q10. Tracks streamed more on Spotify than on YouTube.
--
-- The platform lives in a single column, so the two figures must be
-- pivoted into separate columns via conditional aggregation before they
-- can be compared. The derived table is required because SELECT-list
-- aliases are not visible to WHERE in the same query block.
--
-- `streamed_on_youtube > 0` is what makes the result meaningful: without
-- it, every Spotify-only track passes trivially as `anything > 0`.
SELECT *
FROM (
    SELECT
        track,
        COALESCE(SUM(CASE WHEN most_playedon = 'Youtube' THEN stream END), 0) AS streamed_on_youtube,
        COALESCE(SUM(CASE WHEN most_playedon = 'Spotify' THEN stream END), 0) AS streamed_on_spotify
    FROM spotify
    GROUP BY track
) AS platform_totals
WHERE streamed_on_spotify > streamed_on_youtube
  AND streamed_on_youtube > 0
ORDER BY streamed_on_spotify DESC;


-- ---------------------------------------------------------------------
-- ADVANCED
-- ---------------------------------------------------------------------

-- Q11. Top 3 most-viewed tracks per artist.
--
-- DENSE_RANK is the correct ranking function here: tied tracks share a
-- rank and the next rank is not skipped, so "top 3" returns the three
-- best performance levels. ROW_NUMBER would break ties arbitrarily;
-- RANK would leave gaps.
--
-- The CTE is required because a window function cannot be referenced in
-- the WHERE clause of the query that defines it — window functions are
-- evaluated after WHERE.
WITH ranked_artists AS (
    SELECT
        artist,
        track,
        SUM(views) AS total_views,
        DENSE_RANK() OVER (
            PARTITION BY artist
            ORDER BY SUM(views) DESC
        ) AS view_rank
    FROM spotify
    GROUP BY artist, track
)
SELECT artist, track, total_views, view_rank
FROM ranked_artists
WHERE view_rank <= 3
ORDER BY artist, view_rank;


-- Q12. Tracks with above-average liveness.
-- The threshold is a scalar subquery, not a hard-coded constant, so it
-- recalculates automatically as the data changes.
SELECT track, artist, liveness
FROM spotify
WHERE liveness > (SELECT AVG(liveness) FROM spotify)
ORDER BY liveness DESC;


-- Q13. Energy range (max - min) per album, using a CTE.
WITH energy_stats AS (
    SELECT
        album,
        COUNT(*)    AS track_count,
        MAX(energy) AS highest_energy,
        MIN(energy) AS lowest_energy
    FROM spotify
    GROUP BY album
)
SELECT
    album,
    track_count,
    ROUND(highest_energy, 3)                 AS highest_energy,
    ROUND(lowest_energy, 3)                  AS lowest_energy,
    ROUND(highest_energy - lowest_energy, 3) AS energy_range
FROM energy_stats
WHERE track_count >= 3
ORDER BY energy_range DESC;


-- Q14. Tracks with an energy-to-liveness ratio above 1.2.
SELECT
    track,
    artist,
    ROUND(energy, 3)                       AS energy,
    ROUND(liveness, 3)                     AS liveness,
    ROUND(energy / NULLIF(liveness, 0), 2) AS energy_liveness_ratio
FROM spotify
WHERE liveness > 0
  AND energy / liveness > 1.2
ORDER BY energy_liveness_ratio DESC;


-- Q15. Running total of likes, ordered by views.
-- The frame is stated explicitly rather than relying on the default,
-- which changes behaviour when the ORDER BY column contains ties.
SELECT
    track,
    artist,
    views,
    likes,
    SUM(likes) OVER (
        ORDER BY views DESC, track
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_likes
FROM spotify
ORDER BY views DESC
LIMIT 50;


-- ---------------------------------------------------------------------
-- QUERY OPTIMIZATION
-- ---------------------------------------------------------------------

-- Baseline plan: type = ALL, ~20,592 rows examined (full table scan).
EXPLAIN
SELECT artist, track, views
FROM spotify
WHERE artist = 'Gorillaz'
  AND most_playedon = 'Youtube'
ORDER BY stream DESC
LIMIT 25;

-- No prefix length is needed because `artist` is VARCHAR(100).
-- A TEXT column would require artist(100) here.
CREATE INDEX idx_artist ON spotify(artist);

-- After indexing: type = ref, ~10 rows examined, key = idx_artist.
EXPLAIN
SELECT artist, track, views
FROM spotify
WHERE artist = 'Gorillaz'
  AND most_playedon = 'Youtube'
ORDER BY stream DESC
LIMIT 25;

-- MySQL 8.0.18+ also reports actual timings rather than estimates:
-- EXPLAIN ANALYZE SELECT ... ;
