-- pandoc filter for the published site (scripts/build-site.sh).
--
-- Two rewrites, both about the fact that the site is a subset of the repository:
--   *.md            -> *.html   the page we also publish, so the link stays local
--   anything else   -> GitHub   source files are not published; pointing at the
--                               repository is honest, where a dead relative link
--                               would just 404
-- Absolute URLs and bare anchors are left alone.
local REPO = "https://github.com/IoTone/Telemachus/blob/main/"

local function rewrite(target)
  if target:match("^%a[%w+.-]*:") or target:match("^#") or target:match("^//") then
    return target
  end
  local path, anchor = target:match("^([^#]*)(#?.*)$")
  if path == "" then return target end
  if path:match("%.md$") then
    return (path:gsub("%.md$", ".html")) .. anchor
  end
  -- a path inside the repository that the site does not publish
  local clean = path:gsub("^%./", "")
  local depth = 0
  for _ in clean:gmatch("%.%./") do depth = depth + 1 end
  clean = clean:gsub("%.%./", "")
  local base = os.getenv("SITE_PAGE_DIR") or ""
  -- walk the page's own directory up by the number of ../ segments
  local parts = {}
  for seg in base:gmatch("[^/]+") do parts[#parts+1] = seg end
  for _ = 1, depth do if #parts > 0 then parts[#parts] = nil end end
  local prefix = table.concat(parts, "/")
  if prefix ~= "" then prefix = prefix .. "/" end
  return REPO .. prefix .. clean .. anchor
end

function Link(el)  el.target = rewrite(el.target); return el end
function Image(el) el.src    = rewrite(el.src);    return el end
