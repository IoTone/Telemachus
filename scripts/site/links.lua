-- pandoc filter for the published site (scripts/build-site.sh).
--
-- Two rewrites, both about the fact that the site is a subset of the repository:
--   *.md            -> *.html   the page we also publish, so the link stays local
--   anything else   -> GitHub   source files are not published; pointing at the
--                               repository is honest, where a dead relative link
--                               would just 404
-- Absolute URLs and bare anchors are left alone.
local REPO = "https://github.com/IoTone/Telemachus/blob/main/"

-- repository paths that build-site.sh copies into the site as-is
local PUBLISHED = { "^docs/screenshots/" }

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
  -- dirname gives "." for a page at the repository root; it is not a directory
  -- segment, and keeping it produced blob/main/./docs/... in every README image
  for seg in base:gmatch("[^/]+") do if seg ~= "." then parts[#parts+1] = seg end end
  for _ = 1, depth do if #parts > 0 then parts[#parts] = nil end end
  local prefix = table.concat(parts, "/")
  if prefix ~= "" then prefix = prefix .. "/" end
  local repo_path = prefix .. clean
  -- A PUBLISHED asset stays local. The site mirrors the repository's layout, so
  -- the relative path already resolves; rewriting it would point at a GitHub
  -- blob URL, which serves an HTML page and renders as a BROKEN IMAGE. That is
  -- exactly what the READMEs' feature tour did on the site until 2026-10-14 —
  -- all 19 screenshots, since the site launched. build-site.sh publishes this
  -- directory, and the workflow's link check (which reads src= as well as href=)
  -- is what keeps the two in step: it skips anything starting with http, so an
  -- asset rewritten away from local can never be caught by it.
  for _, pub in ipairs(PUBLISHED) do
    if repo_path:match(pub) then return target end
  end
  return REPO .. repo_path .. anchor
end

function Link(el)  el.target = rewrite(el.target); return el end
function Image(el) el.src    = rewrite(el.src);    return el end
