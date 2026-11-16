-- A distributor's part number is per tool, but it lived on the shared tool_distributors row,
-- so parallel tool imports raced and the last writer won for every tool. Move it onto the
-- per-(tool, distributor) link. The backfill can only copy the racy shared value; a reload
-- (or a targeted re-import of tools) writes the correct per-tool numbers.
ALTER TABLE tool_distributors_links ADD COLUMN part_number TEXT NOT NULL DEFAULT '';
UPDATE tool_distributors_links l SET part_number = d.part_number
    FROM tool_distributors d WHERE d.id = l.tool_distributor_id;
ALTER TABLE tool_distributors DROP COLUMN part_number;
