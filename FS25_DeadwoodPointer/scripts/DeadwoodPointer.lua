-- Deadwood Tree Pointer
--
-- Marks the trees an active deadwood contract actually requires, and points at the ones off-screen.
--
-- ============================================================================
-- HOW A TREE IS IDENTIFIED (this is the whole mod; everything else is presentation)
--
-- The engine already knows which trees belong to a contract, so we ask it rather than reimplementing
-- the contract's geometry:
--
--     g_missionManager:getMissionBySplitShape(node)      -- MissionManager.lua:770, unstripped SDK
--
-- It loops the mission list calling mission:getIsMissionSplitShape(shape). That is map-agnostic: it
-- works on base maps, DLC maps and third-party maps identically, because it never reads map data.
-- The alternative (resolve the contract's spotIndex against <map>.xml -> missions/deadwoodSpots.i3d,
-- read each spot's translation + "radius" user attribute, then test distance) works too, but DLC and
-- mod maps ship those i3ds inside packed archives, so it can't be relied on. Kept as a note only.
--
-- TWO TRAPS, both confirmed by diffing savegame missions.xml before/after felling one tree:
--
--   1. A felled tree STAYS mission-owned. Cutting one turned its <deadTree> entry into
--      cutDown="true" and added two <cutSplitShape> entries (the stump and the trunk), still
--      registered to the mission. So getMissionBySplitShape alone keeps returning a mission for wood
--      the player has already dealt with. `not getIsSplitShapeSplit(node)` is what excludes it --
--      that is Giants' own standing-uncut-tree test (TreePlantManager.lua:1250).
--
--   2. The mission list includes the UNACCEPTED pool. Filter on status == RUNNING and a matching
--      farmId, or you will mark trees for contracts nobody has taken.
--
-- Completion moved to exactly 1/numTrees the instant the chainsaw cut completed -- felling is the
-- trigger, not removal or delivery. So a marker must vanish on the cut, which the split test gives
-- us for free.
--
-- ENUMERATION is two-tier. There is no Lua-enumerable registry of split shapes, and overlapSphere is
-- bounded by a radius around the player -- useless here, because the contract site is routinely
-- hundreds of metres away and the whole point is to guide you TO it.
--
--   Fast path: read mission.deadTrees directly (structure recovered via dwDebug -- see the block
--              above scanFromMissions). Measured at 25 candidates examined.
--   Fallback:  recurse the scene graph from getRootNode(). Measured at ~322,000 nodes on a loaded
--              map -- about 13,000x more work -- so it is a safety net, not the normal route.
--
-- Either way the scan runs only when the running-mission signature changes (accepting a contract,
-- felling a tree) plus a slow safety net -- never per frame.
-- ============================================================================

DeadwoodPointer = {}
local dwp = DeadwoodPointer

dwp.enabled = true
dwp.targets = {}                 -- array of split-shape node ids, still standing, contract-owned
dwp.lastSignature = nil
dwp.sigTimer = 0
dwp.safetyTimer = 0
dwp.lastScanNodes = 0            -- diagnostics for dwDebug
dwp.lastScanMode = "none"        -- 'mission' (fast path) or 'walk' (fallback)
dwp.actionEventId = nil

dwp.SIG_INTERVAL = 500           -- ms between cheap "did anything change" checks
dwp.SAFETY_INTERVAL = 30000      -- ms; full rescan even if nothing looked like it changed
dwp.MAX_DEPTH = 24               -- scene-graph recursion guard

dwp.Y_OFFSET = 2.2               -- lift the marker clear of the trunk and the brush around its base
dwp.BASE_FONT_SIZE = 1.1
dwp.MIN_FONT_SIZE = 0.026        -- never smaller than this, however far away
dwp.MAX_FONT_SIZE = 0.075        -- never larger than this, however close
dwp.EDGE_MARGIN = 0.045          -- how far off-screen arrows sit from the screen border
dwp.EDGE_FONT_SIZE = 0.034
dwp.DEFAULT_FOV = 1.047198       -- 60deg; markers scale by DEFAULT_FOV/currentFov so zoom reads right

-- Colour: the first pass used orange, which disappeared into sunlit bark and brush. Anything outside
-- a forest's natural palette (greens, browns, ochres) survives; violet is well clear of it and reads
-- against both foliage and sky. Kept bright rather than deep -- violet loses luminance fast, and
-- luminance is what carries it at 150m.
dwp.COLOR = {0.78, 0.42, 1.0, 1}         -- violet
dwp.COLOR_EDGE = {0.86, 0.58, 1.0, 1}    -- slightly lighter for the screen-edge arrows

-- Contrast backing. "outline" (a 4-way black halo) is the most legible and the ugliest; in practice
-- the markers read fine at 150m without it, so the default is a single soft drop shadow -- enough to
-- stop the glyph dissolving into a bright sky, without the sticker-like ring.
--   "shadow"  = one offset shadow, subtle          (default)
--   "outline" = 4-way halo, maximum legibility
--   "none"    = flat colour, cleanest, will wash out against bright sky
dwp.BACKING = "shadow"
dwp.COLOR_BACKING = {0, 0, 0.05, 0.5}

-- Subtle size pulse. Static markers vanish into visual noise; a slow breathe catches the eye without
-- being obnoxious. Set to 0 to switch it off.
dwp.PULSE_AMOUNT = 0.09          -- +/- fraction of size
dwp.PULSE_PERIOD = 1600          -- ms per cycle
dwp.pulseTimer = 0

local SETTINGS_DIR  = "modSettings/FS25_DeadwoodPointer/"
local SETTINGS_FILE = "settings.xml"
local SETTINGS_ROOT = "deadwoodPointer"

-- ============================================================================
-- Settings (modSettings, profile-wide -- it's a display preference, not save state)
-- ============================================================================

local function settingsPath()
    if getUserProfileAppPath == nil then
        return nil
    end
    local ok, base = pcall(getUserProfileAppPath)
    if not ok or base == nil then
        return nil
    end
    return base .. SETTINGS_DIR .. SETTINGS_FILE, base .. SETTINGS_DIR
end

function DeadwoodPointer.loadSettings()
    local path = settingsPath()
    if path == nil or XMLFile == nil or XMLFile.loadIfExists == nil then
        return
    end
    local ok, xmlFile = pcall(XMLFile.loadIfExists, "dwPointer", path)
    if not ok or xmlFile == nil then
        return
    end
    pcall(function()
        local v = xmlFile:getBool(SETTINGS_ROOT .. ".pointer#enabled")
        if v ~= nil then
            dwp.enabled = v
        end
    end)
    pcall(function() xmlFile:delete() end)
end

function DeadwoodPointer.saveSettings()
    local path, dir = settingsPath()
    if path == nil or XMLFile == nil or XMLFile.create == nil then
        return false
    end
    if dir ~= nil and createFolder ~= nil then
        pcall(createFolder, dir)
    end
    local ok, xmlFile = pcall(XMLFile.create, "dwPointer", path, SETTINGS_ROOT)
    if not ok or xmlFile == nil then
        return false
    end
    pcall(function()
        xmlFile:setBool(SETTINGS_ROOT .. ".pointer#enabled", dwp.enabled)
        xmlFile:save()
    end)
    pcall(function() xmlFile:delete() end)
    return true
end

-- ============================================================================
-- Contract ownership
-- ============================================================================

local function playerFarmId()
    if g_currentMission == nil then
        return nil
    end
    if g_currentMission.getFarmId ~= nil then
        local ok, id = pcall(g_currentMission.getFarmId, g_currentMission)
        if ok and id ~= nil then
            return id
        end
    end
    return g_currentMission.playerFarmId
end

-- Is this a mission we are actually running? getMissionBySplitShape happily returns unaccepted
-- pool missions, which have no farmId at all.
local function missionIsOurs(mission)
    if mission == nil then
        return false
    end
    if MissionStatus ~= nil and MissionStatus.RUNNING ~= nil and mission.status ~= MissionStatus.RUNNING then
        return false
    end
    local farmId = playerFarmId()
    if mission.farmId == nil then
        return false
    end
    if farmId ~= nil and mission.farmId ~= farmId then
        return false
    end
    return true
end

-- Returns the owning mission if `node` is a standing, uncut, contract-owned tree; else nil.
local function contractTreeMission(node)
    if node == nil or node == 0 then
        return nil
    end
    -- The fast path feeds arbitrary numbers in here (counts, indices, ids), so prove it's a live
    -- entity before asking the engine anything else about it.
    if entityExists ~= nil then
        local ok, exists = pcall(entityExists, node)
        if not ok or not exists then
            return nil
        end
    end
    if getHasClassId == nil or ClassIds == nil or not getHasClassId(node, ClassIds.MESH_SPLIT_SHAPE) then
        return nil
    end
    if getSplitType == nil or getSplitType(node) == 0 then
        return nil
    end
    -- Trap 1: a felled tree and its stump stay mission-owned. Only standing wood is still a target.
    if getIsSplitShapeSplit ~= nil and getIsSplitShapeSplit(node) then
        return nil
    end
    local mm = g_missionManager
    if mm == nil or mm.getMissionBySplitShape == nil then
        return nil
    end
    local ok, mission = pcall(mm.getMissionBySplitShape, mm, node)
    if not ok then
        return nil
    end
    return mission
end

-- ============================================================================
-- Scan
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Fast path: read the mission's own tree list.
--
-- DeadwoodMission is stripped from the SDK dump, so this structure was recovered by dumping a live
-- mission with dwDebug. Confirmed shape:
--
--   mission.deadTrees = {                        -- array, one entry per required tree
--       [1] = { cutDown = false, rootNode = 506632, splitShapeId = 506633,
--               x = 724, z = 508, rotY = -0.53 },
--       [2] = { cutDown = true },                -- felled: EVERY other field is dropped
--       ...
--   }
--   mission.deadTreeShapeToTree      -- splitShapeId -> the same tree table; only uncut trees
--   mission.deadTreeCutSplitShapes   -- id -> true, for the pieces a felled tree broke into
--   mission.numDeadTrees / numCutDownTrees / wronglyCutDownTreesReward
--
-- Note there is no `y` on a tree entry, only x/z, so world position still comes from the node.
--
-- Cheap: a contract has a handful of trees, versus ~322,000 nodes for the scene-graph walk that this
-- replaces. The walk survives as a fallback in rescan() in case a patch renames these fields.
-- Every candidate still goes through contractTreeMission(), so a stale or reused id cannot produce a
-- marker on something that is not a standing, mission-owned tree.
-- ---------------------------------------------------------------------------

local function collectFromDeadTrees(mission, out)
    local trees = mission.deadTrees
    if type(trees) ~= "table" then
        return false
    end
    local sawList = false
    for _, tree in pairs(trees) do
        if type(tree) == "table" then
            sawList = true
            -- cutDown entries carry no splitShapeId at all, so this is belt and braces.
            if tree.cutDown ~= true and type(tree.splitShapeId) == "number" then
                dwp.lastScanNodes = dwp.lastScanNodes + 1
                if contractTreeMission(tree.splitShapeId) == mission then
                    out[#out + 1] = tree.splitShapeId
                end
            end
        end
    end
    return sawList
end

-- Secondary: the shape->tree map is keyed by splitShapeId and only holds uncut trees, so its keys
-- are already the answer. Used if deadTrees is absent or unreadable.
local function collectFromShapeMap(mission, out)
    local map = mission.deadTreeShapeToTree
    if type(map) ~= "table" then
        return false
    end
    local sawMap = false
    for shapeId in pairs(map) do
        if type(shapeId) == "number" then
            sawMap = true
            dwp.lastScanNodes = dwp.lastScanNodes + 1
            if contractTreeMission(shapeId) == mission then
                out[#out + 1] = shapeId
            end
        end
    end
    return sawMap
end

local function scanFromMissions(out)
    local mm = g_missionManager
    if mm == nil or type(mm.missions) ~= "table" then
        return false
    end

    local anyOwner, anyReadable = false, false

    for _, mission in ipairs(mm.missions) do
        if type(mission) == "table" and mission.getIsMissionSplitShape ~= nil and missionIsOurs(mission) then
            anyOwner = true
            local ok = collectFromDeadTrees(mission, out)
            if not ok then
                ok = collectFromShapeMap(mission, out)
            end
            anyReadable = anyReadable or ok
        end
    end

    -- Three outcomes, and they are NOT the same thing:
    --   no contract running        -> empty is correct, do not fall back
    --   contract read, 0 standing  -> all trees felled, empty is correct, do not fall back
    --   contract present but its tables unreadable -> fall back to the walk
    if not anyOwner then
        return true
    end
    return anyReadable
end

local function walk(node, out, depth)
    if node == nil or node == 0 or depth > dwp.MAX_DEPTH then
        return
    end
    local numChildren = getNumOfChildren(node)
    for i = 0, numChildren - 1 do
        local child = getChildAt(node, i)
        dwp.lastScanNodes = dwp.lastScanNodes + 1
        local mission = contractTreeMission(child)
        if mission ~= nil then
            -- A split shape has no children we care about; don't recurse into a match.
            if missionIsOurs(mission) then
                out[#out + 1] = child
            end
        else
            walk(child, out, depth + 1)
        end
    end
end

function DeadwoodPointer.rescan()
    dwp.targets = {}
    dwp.lastScanNodes = 0
    dwp.lastScanMode = "none"

    -- Fast path first: four table lookups instead of a third of a million node visits.
    local out = {}
    local ok, satisfied = pcall(scanFromMissions, out)
    if ok and satisfied then
        dwp.lastScanMode = "mission"
        dwp.targets = out
        return #out
    end

    -- Fallback: full scene-graph walk.
    out = {}
    dwp.lastScanNodes = 0
    if getRootNode == nil or getNumOfChildren == nil or getChildAt == nil then
        return 0
    end
    local root = getRootNode()
    if root == nil or root == 0 then
        return 0
    end
    pcall(walk, root, out, 0)
    dwp.lastScanMode = "walk"
    dwp.targets = out
    return #out
end

-- Cheap "has anything changed" probe. completion moves the instant a tree is felled, so this
-- catches progress without walking the scene graph.
local function missionSignature()
    local mm = g_missionManager
    if mm == nil or type(mm.missions) ~= "table" then
        return ""
    end
    local parts = {}
    for _, m in ipairs(mm.missions) do
        if type(m) == "table" and m.farmId ~= nil then
            parts[#parts + 1] = tostring(m.uniqueId or "?") .. ":" .. tostring(m.status) .. ":" .. tostring(m.completion or 0)
        end
    end
    return table.concat(parts, "|")
end

-- Drop anything that has been deleted or felled since the last full scan. Runs every frame and is
-- what makes a marker vanish the moment the cut finishes, without waiting for a rescan.
local function pruneTargets()
    if #dwp.targets == 0 then
        return
    end
    local kept = {}
    for _, node in ipairs(dwp.targets) do
        local alive = (entityExists == nil or entityExists(node))
            and not (getIsSplitShapeSplit ~= nil and getIsSplitShapeSplit(node))
        if alive then
            kept[#kept + 1] = node
        end
    end
    dwp.targets = kept
end

-- ============================================================================
-- Frame-facing API
-- ============================================================================

function DeadwoodPointer.isEnabled()
    return dwp.enabled == true
end

function DeadwoodPointer.setEnabled(enabled)
    dwp.enabled = enabled == true
    if dwp.enabled then
        dwp.lastSignature = nil     -- force a rescan on the next tick
    else
        dwp.targets = {}
    end
    DeadwoodPointer.saveSettings()
    return dwp.enabled
end

function DeadwoodPointer.toggleEnabled()
    local on = DeadwoodPointer.setEnabled(not dwp.enabled)
    local text = on and "dwPointer_on" or "dwPointer_off"
    if g_currentMission ~= nil and g_currentMission.hud ~= nil and g_i18n ~= nil then
        pcall(function()
            g_currentMission.hud:addSideNotification(nil, g_i18n:getText(text))
        end)
    end
    return on
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

function DeadwoodPointer:loadMap(name)
    DeadwoodPointer.loadSettings()
    dwp.targets = {}
    dwp.lastSignature = nil

    addConsoleCommand("dwPointer", "Toggle the deadwood contract tree pointer", "consoleToggle", DeadwoodPointer)
    addConsoleCommand("dwDebug", "Report what the deadwood pointer can see", "consoleDebug", DeadwoodPointer)
end

function DeadwoodPointer:deleteMap()
    dwp.targets = {}
    dwp.actionEventId = nil
end

function DeadwoodPointer:onToggleAction()
    DeadwoodPointer.toggleEnabled()
end

function DeadwoodPointer:update(dt)
    if not dwp.enabled then
        return
    end
    if g_currentMission == nil or g_missionManager == nil then
        return
    end

    pruneTargets()

    dwp.pulseTimer = (dwp.pulseTimer + dt) % dwp.PULSE_PERIOD
    dwp.sigTimer = dwp.sigTimer + dt
    dwp.safetyTimer = dwp.safetyTimer + dt

    if dwp.sigTimer >= dwp.SIG_INTERVAL then
        dwp.sigTimer = 0
        local sig = missionSignature()
        if sig ~= dwp.lastSignature then
            dwp.lastSignature = sig
            DeadwoodPointer.rescan()
            dwp.safetyTimer = 0
        end
    end

    if dwp.safetyTimer >= dwp.SAFETY_INTERVAL then
        dwp.safetyTimer = 0
        DeadwoodPointer.rescan()
    end
end

-- ============================================================================
-- Render
-- ============================================================================

-- Unicode arrows render fine in this engine -- NucleusStumps ships "\u{2193}" and it draws correctly.
-- These all live in the same U+2190-2199 block, so the font subset covering one covers the rest.
-- If any of them ever draw blank, swap this table and MARKER_GLYPH for ASCII "<", ">", "^", "v".
local EDGE_ARROWS = {"←", "↙", "↓", "↘", "→", "↗", "↑", "↖"}
local MARKER_GLYPH = "↓"

-- renderText has no outline or shadow support, so both are faked by stamping the glyph in near-black
-- behind the real one. See dwp.BACKING for the trade-off between legibility and looking clean.
local function renderTextOutlined(x, y, size, text, colour)
    local mode = dwp.BACKING
    if mode == "outline" or mode == "shadow" then
        local b = dwp.COLOR_BACKING
        setTextColor(b[1], b[2], b[3], b[4])
        if mode == "outline" then
            local offset = size * 0.07
            renderText(x - offset, y, size, text)
            renderText(x + offset, y, size, text)
            renderText(x, y - offset, size, text)
            renderText(x, y + offset, size, text)
        else
            -- Single offset down and right: reads as depth rather than as a border.
            local offset = size * 0.05
            renderText(x + offset, y - offset, size, text)
        end
    end
    setTextColor(colour[1], colour[2], colour[3], colour[4])
    renderText(x, y, size, text)
end

local function drawEdgeArrow(sx, sy, behind)
    -- Behind the camera, project() mirrors the point; flip it back so the arrow points the right way.
    if behind then
        sx, sy = 1 - sx, 1 - sy
    end

    local dx, dy = sx - 0.5, sy - 0.5
    if dx == 0 and dy == 0 then
        dy = -0.0001
    end

    local limit = 0.5 - dwp.EDGE_MARGIN
    local scale = math.min(limit / math.max(math.abs(dx), 1e-6), limit / math.max(math.abs(dy), 1e-6))
    local ex, ey = 0.5 + dx * scale, 0.5 + dy * scale

    local angle = math.atan2(dy, dx)
    local index = math.floor(((angle + math.pi) / (2 * math.pi)) * 8 + 0.5) % 8
    return ex, ey, EDGE_ARROWS[index + 1]
end

function DeadwoodPointer:draw()
    if not dwp.enabled or #dwp.targets == 0 then
        return
    end
    if getCamera == nil or project == nil or renderText == nil then
        return
    end

    local cam = getCamera()
    if cam == nil or cam == 0 then
        return
    end

    local fov = (getFovY ~= nil) and getFovY(cam) or dwp.DEFAULT_FOV
    local fovFactor = (fov ~= nil and fov ~= 0) and (dwp.DEFAULT_FOV / fov) or 1

    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextBold(true)

    local pulse = 1
    if dwp.PULSE_AMOUNT > 0 and dwp.PULSE_PERIOD > 0 then
        pulse = 1 + dwp.PULSE_AMOUNT * math.sin(dwp.pulseTimer / dwp.PULSE_PERIOD * 2 * math.pi)
    end

    local nearest = nil

    for _, node in ipairs(dwp.targets) do
        local wx, wy, wz = getWorldTranslation(node)
        local distance = (calcDistanceFrom ~= nil) and calcDistanceFrom(node, cam) or 0
        if distance <= 0 then
            distance = 1
        end
        if nearest == nil or distance < nearest then
            nearest = distance
        end

        local sx, sy, sz = project(wx, wy + dwp.Y_OFFSET, wz)
        local onScreen = sz <= 1 and sx > 0 and sx < 1 and sy > 0 and sy < 1

        if onScreen then
            local size = dwp.BASE_FONT_SIZE / distance * fovFactor
            if size < dwp.MIN_FONT_SIZE then size = dwp.MIN_FONT_SIZE end
            if size > dwp.MAX_FONT_SIZE then size = dwp.MAX_FONT_SIZE end
            size = size * pulse

            renderTextOutlined(sx, sy, size, MARKER_GLYPH, dwp.COLOR)
            renderTextOutlined(sx, sy - size * 0.85, size * 0.5,
                string.format("%dm", math.floor(distance + 0.5)), dwp.COLOR)
        else
            local ex, ey, arrow = drawEdgeArrow(sx, sy, sz > 1)
            local size = dwp.EDGE_FONT_SIZE * pulse
            renderTextOutlined(ex, ey, size, arrow, dwp.COLOR_EDGE)
            renderTextOutlined(ex, ey - size * 0.9, size * 0.55,
                string.format("%dm", math.floor(distance + 0.5)), dwp.COLOR_EDGE)
        end
    end

    -- Summary: the thing that actually answers "how much is left and which way".
    local summary
    if nearest ~= nil then
        summary = string.format("Deadwood contract: %d left  -  nearest %dm", #dwp.targets, math.floor(nearest + 0.5))
    else
        summary = string.format("Deadwood contract: %d left", #dwp.targets)
    end
    renderTextOutlined(0.5, 0.952, 0.020, summary, dwp.COLOR)

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    setTextBold(false)
end

-- ============================================================================
-- Console
-- ============================================================================

function DeadwoodPointer:consoleToggle()
    local on = DeadwoodPointer.toggleEnabled()
    return on and "Deadwood Pointer ON" or "Deadwood Pointer OFF"
end

-- First-run verification, and the hook for making the scan cheaper later: dumps the running
-- missions and the top-level keys of any mission that owns trees. If one of those keys turns out to
-- hold the tree list directly, the scene-graph walk can be replaced with a direct read.
function DeadwoodPointer:consoleDebug()
    local lines = {}
    local function add(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end

    add("enabled=%s  targets=%d  lastScanVisited=%d  farmId=%s",
        tostring(dwp.enabled), #dwp.targets, dwp.lastScanNodes, tostring(playerFarmId()))

    local found = DeadwoodPointer.rescan()
    add("rescan -> %d target(s) via '%s', %d candidate(s)/node(s) examined",
        found, tostring(dwp.lastScanMode), dwp.lastScanNodes)

    local mm = g_missionManager
    if mm == nil or type(mm.missions) ~= "table" then
        add("g_missionManager.missions unavailable")
        return table.concat(lines, "\n")
    end

    for i, m in ipairs(mm.missions) do
        if type(m) == "table" and m.farmId ~= nil then
            local typeName = "?"
            if m.getMissionTypeName ~= nil then
                local ok, n = pcall(m.getMissionTypeName, m)
                if ok then typeName = tostring(n) end
            end
            add("mission[%d] type=%s status=%s farmId=%s completion=%s ours=%s",
                i, typeName, tostring(m.status), tostring(m.farmId), tostring(m.completion),
                tostring(missionIsOurs(m)))
            if m.getIsMissionSplitShape ~= nil then
                local keys = {}
                for k, v in pairs(m) do
                    keys[#keys + 1] = string.format("%s(%s)", tostring(k), type(v))
                end
                table.sort(keys)
                add("  owns trees; keys: %s", table.concat(keys, " "))

                -- Structure of the tables the fast path reads, so the guesswork can be replaced
                -- with a direct field read once we can see their shape.
                for _, field in ipairs({"deadTrees", "deadTreeShapeToTree", "deadTreeCutSplitShapes", "spot"}) do
                    local t = m[field]
                    if type(t) == "table" then
                        local n = 0
                        for _ in pairs(t) do n = n + 1 end
                        add("  %s: %d entr(y/ies)", field, n)
                        local limit = (field == "spot") and 20 or 3
                        local shown = 0
                        for k, v in pairs(t) do
                            if shown >= limit then
                                add("    ...")
                                break
                            end
                            if type(v) == "table" then
                                local inner = {}
                                for ik, iv in pairs(v) do
                                    inner[#inner + 1] = string.format("%s=%s(%s)", tostring(ik), tostring(iv), type(iv))
                                end
                                table.sort(inner)
                                add("    [%s(%s)] -> {%s}", tostring(k), type(k), table.concat(inner, " "))
                            else
                                add("    [%s(%s)] -> %s(%s)", tostring(k), type(k), tostring(v), type(v))
                            end
                            shown = shown + 1
                        end
                    elseif t ~= nil then
                        add("  %s: %s(%s)", field, tostring(t), type(t))
                    end
                end
            end
        end
    end

    for i, node in ipairs(dwp.targets) do
        local wx, wy, wz = getWorldTranslation(node)
        local p1, p2, p3 = 0, 0, 0
        if getSaveableSplitShapeId ~= nil then
            local ok, a, b, c = pcall(getSaveableSplitShapeId, node)
            if ok then p1, p2, p3 = a or 0, b or 0, c or 0 end
        end
        local splitTypeName = "?"
        if g_splitShapeManager ~= nil and g_splitShapeManager.getSplitTypeNameByIndex ~= nil then
            local ok, n = pcall(g_splitShapeManager.getSplitTypeNameByIndex, g_splitShapeManager, getSplitType(node))
            if ok then splitTypeName = tostring(n) end
        end
        add("target[%d] node=%s type=%s pos=%.1f/%.1f/%.1f saveableId=%s/%s/%s",
            i, tostring(node), splitTypeName, wx, wy, wz, tostring(p1), tostring(p2), tostring(p3))
    end

    return table.concat(lines, "\n")
end

-- ============================================================================
-- Input
--
-- The toggle CANNOT be registered from loadMap. registerActionEvent only does anything while an
-- action-events modification context is open, and none is open at loadMap time -- it registers
-- nothing, silently, and the binding still appears in the options menu because that comes from
-- modDesc.xml. The symptom is a key that rebinds fine and does nothing when pressed.
--
-- The working shape (same as FS25_NucleusCommand's F12, and EDC's, both confirmed in game): hook
-- PlayerInputComponent.registerGlobalPlayerActionEvents, and open our OWN begin/end pair around the
-- registration rather than assuming the base call left one open -- it calls
-- endActionEventsModification partway through its own body, well before an appendedFunction hook
-- gets to run. Restoring the previous context is done with beginActionEventsModification(previous),
-- mirroring the proven implementation.
--
-- Hooked at file-load time, before any player exists, so it is in place for the first registration.
-- ============================================================================

local function registerGlobalActionEvents(playerInputComponent, contextName)
    if playerInputComponent == nil or playerInputComponent.player == nil then
        return
    end
    if not playerInputComponent.player.isOwner then
        return
    end
    if g_inputBinding == nil then
        return
    end

    local action = (InputAction ~= nil and InputAction.DWPOINTER_TOGGLE) or "DWPOINTER_TOGGLE"

    local previousContextName = g_inputBinding:getContextName()
    local targetContextName = contextName or previousContextName

    if previousContextName ~= targetContextName then
        g_inputBinding:beginActionEventsModification(targetContextName)
    end

    local _, eventId = g_inputBinding:registerActionEvent(
        action, DeadwoodPointer, DeadwoodPointer.onToggleAction, false, true, false, true)
    dwp.actionEventId = eventId
    if eventId ~= nil then
        g_inputBinding:setActionEventTextVisibility(eventId, false)
    end

    if previousContextName ~= targetContextName then
        g_inputBinding:beginActionEventsModification(previousContextName)
    end
end

if PlayerInputComponent ~= nil and PlayerInputComponent.registerGlobalPlayerActionEvents ~= nil then
    PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
        PlayerInputComponent.registerGlobalPlayerActionEvents, registerGlobalActionEvents)
end

addModEventListener(DeadwoodPointer)
