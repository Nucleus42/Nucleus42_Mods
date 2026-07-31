--
-- AutoDrive Field Loops
--
-- Builds a two-way AutoDrive ring route just inside a field boundary.
--
-- Two sources of field shape:
--   "map"  - field:getDensityMapPolygon(), the surveyed boundary from the map file.
--            Instant, needs no vehicle, but never changes no matter what you plough.
--   "scan" - flood fills the ground-type density map outward from where you stand and
--            traces the outline of what it finds. Slower, but sees fields you have
--            extended or ploughed together.
--
-- Generated waypoints are tagged with FLAG_OWNED so they can be found and removed later
-- without keeping any ids around. AutoDrive renumbers the whole graph on every deletion,
-- so stored id ranges would be worthless.
--

ADFieldLoops = {}

ADFieldLoops.FLAG_SUBPRIO = 1
-- Must stay inside AutoDrive's 5-bit flag field (Sync.lua FLAG_SEND_NUM_BITS = 5, so 0..31)
-- or the tag is lost on the multiplayer round trip. AutoDrive uses 1, 2 and 4;
-- FS25_AutoDrive_RoadFollow claims 16, so FieldLoops takes 8.
ADFieldLoops.FLAG_OWNED = 8

ADFieldLoops.OFFSET = 8
ADFieldLoops.SPACING = 5
ADFieldLoops.SMOOTH_PASSES = 4
ADFieldLoops.SCAN_RES = 2
ADFieldLoops.MAX_SCAN_CELLS = 250000
ADFieldLoops.MIN_RING_POINTS = 8

local function say(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    print("[ADFieldLoops] " .. msg)
    return msg
end

-- Each mod's scripts run in their own sandboxed environment, so another mod's globals are
-- not visible just by naming them. getfenv(0) is the real global table; AutoDrive's own
-- definitions live in whichever environment the engine gave it. Go and find it.
local ROOT = getfenv(0)

local AD, ADG, ADCreate, ADDelete
ADFieldLoops.envName = nil

local function looksLikeAutoDrive(t)
    if type(t) ~= "table" then
        return false
    end
    local ok, res = pcall(function()
        return type(t.AutoDrive) == "table" and type(t.ADGraphManager) == "table"
    end)
    return ok and res == true
end

-- Given any function AutoDrive defined, getfenv on it hands back the environment that
-- function was compiled in - which is exactly the table holding all of AutoDrive's globals.
local function envFromFunction(f)
    if type(f) ~= "function" then
        return nil
    end
    local ok, env = pcall(getfenv, f)
    if ok and looksLikeAutoDrive(env) then
        return env
    end
    return nil
end

-- A value may be the environment itself, a function from it, or a table of such functions
-- (a specialization class, for instance).
local function envFromValue(v)
    if looksLikeAutoDrive(v) then
        return v
    end
    local direct = envFromFunction(v)
    if direct ~= nil then
        return direct
    end
    if type(v) == "table" then
        local found = nil
        pcall(function()
            for _, inner in pairs(v) do
                found = envFromFunction(inner)
                if found ~= nil then
                    return
                end
            end
        end)
        return found
    end
    return nil
end

-- Ordered list of places AutoDrive can be reached from, most direct first.
local function accessRoutes()
    local routes = {}
    local function add(label, getter)
        routes[#routes + 1] = { label = label, get = getter }
    end

    add("this mod's own environment", function() return getfenv(1) end)
    add("root global table", function() return ROOT end)

    -- Specializations are namespaced by mod, e.g. "FS25_AutoDrive.AutoDrive", so match on the
    -- suffix rather than a hardcoded mod name - the folder can be renamed.
    local sm = ROOT.g_specializationManager
    if sm ~= nil then
        local function adSpecNames()
            local names = {}
            pcall(function()
                for k in pairs(sm.specializations or {}) do
                    if type(k) == "string" and (k:sub(-10) == ".AutoDrive" or k == "AutoDrive") then
                        names[#names + 1] = k
                    end
                end
            end)
            return names
        end

        add("g_specializationManager namespaced AutoDrive spec", function()
            for _, name in ipairs(adSpecNames()) do
                local obj = nil
                if sm.getSpecializationObjectByName then
                    obj = sm:getSpecializationObjectByName(name)
                end
                if obj == nil and sm.getSpecializationByName then
                    obj = sm:getSpecializationByName(name)
                end
                local e = envFromValue(obj)
                if e ~= nil then
                    return e
                end
            end
            return nil
        end)
    end

    local psm = ROOT.g_placeableSpecializationManager
    if psm ~= nil then
        add("g_placeableSpecializationManager AutoDrivePlaceableData", function()
            if psm.getSpecializationObjectByName then
                return psm:getSpecializationObjectByName("AutoDrivePlaceableData")
            end
            return psm.getSpecializationByName and psm:getSpecializationByName("AutoDrivePlaceableData") or nil
        end)
    end

    local vtm = ROOT.g_vehicleTypeManager
    if vtm ~= nil and vtm.types ~= nil then
        add("g_vehicleTypeManager specialization sweep", function()
            for _, typeDef in pairs(vtm.types) do
                local byName = typeDef.specializationsByName
                if type(byName) == "table" then
                    for name, obj in pairs(byName) do
                        if type(name) == "string" and name:find("AutoDrive") then
                            local e = envFromValue(obj)
                            if e then
                                return e
                            end
                        end
                    end
                end
            end
            return nil
        end)
    end

    add("root global table deep sweep", function()
        for k, v in pairs(ROOT) do
            if type(k) == "string" then
                local e = envFromValue(v)
                if e then
                    return e
                end
            end
        end
        return nil
    end)

    return routes
end

local function findAutoDriveEnv()
    for _, route in ipairs(accessRoutes()) do
        local ok, value = pcall(route.get)
        if ok and value ~= nil then
            local env = envFromValue(value)
            if env ~= nil then
                return env, route.label
            end
        end
    end
    return nil, nil
end

local function bindAutoDrive()
    -- resolved once per session; the sweep is not free
    if AD ~= nil and ADG ~= nil and ADCreate ~= nil and ADDelete ~= nil then
        return true
    end
    local env, where = findAutoDriveEnv()
    if env == nil then
        return false
    end
    AD = env.AutoDrive
    ADG = env.ADGraphManager
    ADCreate = env.CreatePlaceableEvent
    ADDelete = env.AutoDriveDeleteWayPointsEvent
    ADFieldLoops.envName = where
    return AD ~= nil and ADG ~= nil and ADCreate ~= nil and ADDelete ~= nil
end

local function isReady()
    if not bindAutoDrive() then
        return false, "could not reach AutoDrive's script environment. Run adflDiag and send me the output."
    end
    if ROOT.g_currentMission == nil or ROOT.g_farmlandManager == nil then
        return false, "no mission loaded yet."
    end
    return true
end

-- ---------------------------------------------------------------- vector helpers

local function dist(ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    return math.sqrt(dx * dx + dz * dz)
end

local function distToSegment(px, pz, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local l2 = dx * dx + dz * dz
    if l2 <= 0.0000001 then
        return dist(px, pz, ax, az)
    end
    local t = ((px - ax) * dx + (pz - az) * dz) / l2
    t = math.max(0, math.min(1, t))
    return dist(px, pz, ax + t * dx, az + t * dz)
end

local function segmentsIntersect(a, b, c, d)
    local r1, r2 = b.x - a.x, b.z - a.z
    local s1, s2 = d.x - c.x, d.z - c.z
    local denom = r1 * s2 - r2 * s1
    if math.abs(denom) < 0.000001 then
        return false
    end
    local t = ((c.x - a.x) * s2 - (c.z - a.z) * s1) / denom
    local u = ((c.x - a.x) * r2 - (c.z - a.z) * r1) / denom
    return t > 0.001 and t < 0.999 and u > 0.001 and u < 0.999
end

local function signedArea(poly)
    local a, n = 0, #poly
    for i = 1, n do
        local p, q = poly[i], poly[(i % n) + 1]
        a = a + (p.x * q.z - q.x * p.z)
    end
    return a * 0.5
end

local function makeCounterClockwise(poly)
    if signedArea(poly) < 0 then
        local out = {}
        for i = #poly, 1, -1 do
            out[#out + 1] = poly[i]
        end
        return out
    end
    return poly
end

local function pointInPolygon(px, pz, poly)
    local inside, n = false, #poly
    local j = n
    for i = 1, n do
        local a, b = poly[i], poly[j]
        if ((a.z > pz) ~= (b.z > pz)) and (px < (b.x - a.x) * (pz - a.z) / (b.z - a.z) + a.x) then
            inside = not inside
        end
        j = i
    end
    return inside
end

-- ---------------------------------------------------------------- polygon pipeline

-- Resample a closed ring to evenly spaced points. The step is rounded so it divides the
-- perimeter exactly, otherwise the wrap-around gap ends up longer or shorter than the rest.
local function resampleClosed(poly, spacing)
    local n = #poly
    if n < 3 then
        return poly
    end

    local segLens, perimeter = {}, 0
    for i = 1, n do
        local a, b = poly[i], poly[(i % n) + 1]
        segLens[i] = dist(a.x, a.z, b.x, b.z)
        perimeter = perimeter + segLens[i]
    end
    if perimeter < spacing * 3 then
        return poly
    end

    local count = math.max(3, math.floor(perimeter / spacing + 0.5))
    local step = perimeter / count

    local out = {}
    local seg, along = 1, 0
    for k = 0, count - 1 do
        local target = k * step
        while seg <= n and along + segLens[seg] < target do
            along = along + segLens[seg]
            seg = seg + 1
        end
        if seg > n then
            break
        end
        local a, b = poly[seg], poly[(seg % n) + 1]
        local t = segLens[seg] > 0.0001 and (target - along) / segLens[seg] or 0
        out[#out + 1] = { x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t }
    end
    return out
end

local function offsetInward(poly, d)
    local n, out = #poly, {}
    for i = 1, n do
        local prev = poly[((i - 2) % n) + 1]
        local next = poly[(i % n) + 1]
        local tx, tz = next.x - prev.x, next.z - prev.z
        local l = math.sqrt(tx * tx + tz * tz)
        if l > 0.0001 then
            tx, tz = tx / l, tz / l
            -- polygon is counter-clockwise, so the inward normal is (-tz, tx)
            out[#out + 1] = { x = poly[i].x - tz * d, z = poly[i].z + tx * d }
        end
    end
    return out
end

-- Inward offsetting folds the boundary back on itself in narrow necks and notches.
-- Anything that ends up closer to the original edge than it should be is a fold.
local function dropFoldedPoints(poly, source, minDist)
    local out, sn = {}, #source
    for _, p in ipairs(poly) do
        local best = math.huge
        for i = 1, sn do
            local a, b = source[i], source[(i % sn) + 1]
            local dd = distToSegment(p.x, p.z, a.x, a.z, b.x, b.z)
            if dd < best then
                best = dd
                if best < minDist then
                    break
                end
            end
        end
        if best >= minDist then
            out[#out + 1] = p
        end
    end
    return out
end

-- Smoothing cuts inside corners, which at a reflex corner of the field means drifting back
-- towards the hedge. Push anything that got too close back out to the requested clearance.
local function enforceClearance(poly, source, target, iterations)
    local sn = #source
    for _ = 1, (iterations or 3) do
        local moved = false
        for _, p in ipairs(poly) do
            local best, bx, bz = math.huge, nil, nil
            for i = 1, sn do
                local a, b = source[i], source[(i % sn) + 1]
                local dx, dz = b.x - a.x, b.z - a.z
                local l2 = dx * dx + dz * dz
                local t = 0
                if l2 > 0.0000001 then
                    t = math.max(0, math.min(1, ((p.x - a.x) * dx + (p.z - a.z) * dz) / l2))
                end
                local cx, cz = a.x + t * dx, a.z + t * dz
                local d = dist(p.x, p.z, cx, cz)
                if d < best then
                    best, bx, bz = d, cx, cz
                end
            end
            if best < target - 0.05 and best > 0.0001 then
                local ux, uz = (p.x - bx) / best, (p.z - bz) / best
                p.x = bx + ux * target
                p.z = bz + uz * target
                moved = true
            end
        end
        if not moved then
            return poly
        end
    end
    return poly
end

local function removeSelfIntersections(poly)
    local guard = 0
    while guard < 200 do
        guard = guard + 1
        local n = #poly
        if n < 5 then
            return poly
        end
        local cut = false
        for i = 1, n - 2 do
            local a, b = poly[i], poly[i + 1]
            for j = i + 2, n do
                if not (i == 1 and j == n) then
                    local c, d = poly[j], poly[(j % n) + 1]
                    if segmentsIntersect(a, b, c, d) then
                        -- two ways round; keep whichever loop holds more points
                        local inner = j - i
                        if inner * 2 <= n then
                            for k = j, i + 1, -1 do
                                table.remove(poly, k)
                            end
                        else
                            local kept = {}
                            for k = i + 1, j do
                                kept[#kept + 1] = poly[k]
                            end
                            poly = kept
                        end
                        cut = true
                        break
                    end
                end
            end
            if cut then
                break
            end
        end
        if not cut then
            return poly
        end
    end
    return poly
end

local function smoothClosed(poly, passes)
    for _ = 1, passes do
        local n = #poly
        if n < 5 then
            return poly
        end
        local out = {}
        for i = 1, n do
            local a = poly[((i - 2) % n) + 1]
            local b = poly[i]
            local c = poly[(i % n) + 1]
            out[i] = { x = 0.25 * a.x + 0.5 * b.x + 0.25 * c.x, z = 0.25 * a.z + 0.5 * b.z + 0.25 * c.z }
        end
        poly = out
    end
    return poly
end

local function simplify(poly, epsilon)
    -- Douglas-Peucker on an open run; the ring is cut at index 1 and rejoined after
    local function rdp(pts, first, last, keep)
        local maxD, idx = 0, nil
        local a, b = pts[first], pts[last]
        for i = first + 1, last - 1 do
            local d = distToSegment(pts[i].x, pts[i].z, a.x, a.z, b.x, b.z)
            if d > maxD then
                maxD, idx = d, i
            end
        end
        if idx and maxD > epsilon then
            rdp(pts, first, idx, keep)
            rdp(pts, idx, last, keep)
        else
            keep[last] = true
        end
    end
    local n = #poly
    if n < 4 then
        return poly
    end
    local keep = { [1] = true }
    rdp(poly, 1, n, keep)
    local out = {}
    for i = 1, n do
        if keep[i] then
            out[#out + 1] = poly[i]
        end
    end
    return out
end

-- ---------------------------------------------------------------- field shape sources

local function polygonFromMap(field)
    if field == nil or field.getDensityMapPolygon == nil then
        return nil
    end
    local dmp = field:getDensityMapPolygon()
    if dmp == nil then
        return nil
    end
    local verts = dmp:getVerticesList()
    if verts == nil or #verts < 6 then
        return nil
    end
    local poly = {}
    for i = 1, #verts - 1, 2 do
        poly[#poly + 1] = { x = verts[i], z = verts[i + 1] }
    end
    return poly
end

local function isFieldGround(x, z)
    local y = ROOT.getTerrainHeightAtWorldPos(ROOT.g_currentMission.terrainRootNode, x, 0, z)
    local onField = ROOT.FSDensityMapUtil.getFieldDataAtWorldPosition(x, y, z)
    return onField == true
end

-- Flood fill the ground-type map from a seed, then trace the outline of the region found.
-- This is what sees fields you have made bigger or ploughed into one another.
local function polygonFromScan(seedX, seedZ, res)
    res = res or ADFieldLoops.SCAN_RES

    if not isFieldGround(seedX, seedZ) then
        return nil, "you are not standing on field ground"
    end

    local cells, queue, head = {}, { { 0, 0 } }, 1
    local minI, maxI, minJ, maxJ = 0, 0, 0, 0
    local count = 0
    cells["0:0"] = true

    while head <= #queue do
        local c = queue[head]
        head = head + 1
        local ci, cj = c[1], c[2]
        count = count + 1
        if count > ADFieldLoops.MAX_SCAN_CELLS then
            return nil, string.format("scan area exceeded %d cells, aborting", ADFieldLoops.MAX_SCAN_CELLS)
        end
        if ci < minI then minI = ci end
        if ci > maxI then maxI = ci end
        if cj < minJ then minJ = cj end
        if cj > maxJ then maxJ = cj end

        local neighbours = { { ci + 1, cj }, { ci - 1, cj }, { ci, cj + 1 }, { ci, cj - 1 } }
        for _, nb in ipairs(neighbours) do
            local key = nb[1] .. ":" .. nb[2]
            if cells[key] == nil then
                local wx = seedX + nb[1] * res
                local wz = seedZ + nb[2] * res
                if isFieldGround(wx, wz) then
                    cells[key] = true
                    queue[#queue + 1] = nb
                else
                    cells[key] = false
                end
            end
        end
    end

    if count < 20 then
        return nil, "scanned region is too small to be a field"
    end

    -- Moore boundary trace, starting from the westmost cell of the lowest row
    local startI, startJ
    for j = minJ, maxJ do
        for i = minI, maxI do
            if cells[i .. ":" .. j] then
                startI, startJ = i, j
                break
            end
        end
        if startI then
            break
        end
    end

    local dirs = {
        { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 },
        { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 },
    }
    local outline = {}
    local ci, cj, backtrack = startI, startJ, 5
    local steps = 0
    repeat
        outline[#outline + 1] = { x = seedX + ci * res, z = seedZ + cj * res }
        local found = false
        -- start one past the cell we came from, otherwise we walk straight back into it
        for k = 1, 8 do
            local d = ((backtrack + k - 1) % 8) + 1
            local ni, nj = ci + dirs[d][1], cj + dirs[d][2]
            if cells[ni .. ":" .. nj] then
                backtrack = ((d + 4 - 1) % 8) + 1
                ci, cj = ni, nj
                found = true
                break
            end
        end
        steps = steps + 1
        if not found then
            break
        end
    until (ci == startI and cj == startJ) or steps > 200000

    if #outline < 8 then
        return nil, "could not trace an outline around the scanned region"
    end
    return simplify(outline, res * 0.75)
end

-- ---------------------------------------------------------------- ring construction

local function buildRing(poly, offset, spacing)
    poly = makeCounterClockwise(poly)

    local dense = resampleClosed(poly, math.max(1, spacing * 0.5))
    if #dense < ADFieldLoops.MIN_RING_POINTS then
        return nil, "field boundary has too few points"
    end

    -- A negative offset pushes the ring outside the boundary. Everything downstream cares
    -- about distance from the edge, not which side of it, so work with the magnitude.
    local clearance = math.abs(offset)

    local ring = offsetInward(dense, offset)
    ring = dropFoldedPoints(ring, poly, clearance * 0.8)
    if #ring < ADFieldLoops.MIN_RING_POINTS then
        return nil, string.format("nothing left after offsetting %.1f m, field is too narrow for that", offset)
    end

    ring = removeSelfIntersections(ring)
    ring = smoothClosed(ring, ADFieldLoops.SMOOTH_PASSES)
    ring = enforceClearance(ring, poly, clearance)
    ring = resampleClosed(ring, spacing)
    ring = enforceClearance(ring, poly, clearance, 2)

    if #ring < ADFieldLoops.MIN_RING_POINTS then
        return nil, "ring collapsed during smoothing"
    end
    return ring
end

local function ownedWaypoints()
    local owned = {}
    for _, wp in pairs(ADG:getWayPoints()) do
        if wp.flags ~= nil and ROOT.bit32.band(wp.flags, ADFieldLoops.FLAG_OWNED) > 0 then
            owned[#owned + 1] = wp
        end
    end
    return owned
end

-- Comparing every existing waypoint against every ring point is O(N x n), which on a mature
-- network of 12k+ waypoints stalls the game. Narrow by centroid first, then do the exact
-- comparison on only the closest handful.
local function nearestForeignWaypoint(ring)
    local cx, cz = 0, 0
    for _, p in ipairs(ring) do
        cx, cz = cx + p.x, cz + p.z
    end
    cx, cz = cx / #ring, cz / #ring

    local shortlist = {}
    for _, wp in pairs(ADG:getWayPoints()) do
        if wp.flags == nil or ROOT.bit32.band(wp.flags, ADFieldLoops.FLAG_OWNED) == 0 then
            shortlist[#shortlist + 1] = { wp = wp, d = dist(cx, cz, wp.x, wp.z) }
        end
    end
    if #shortlist == 0 then
        return nil, nil
    end
    table.sort(shortlist, function(a, b) return a.d < b.d end)

    local best, bestD = nil, math.huge
    for i = 1, math.min(50, #shortlist) do
        local wp = shortlist[i].wp
        for _, p in ipairs(ring) do
            local d = dist(p.x, p.z, wp.x, wp.z)
            if d < bestD then
                best, bestD = p, d
            end
        end
    end
    return best, bestD
end

local function uniqueMarkerName(base)
    local taken = {}
    for _, m in pairs(ADG:getMapMarkers()) do
        taken[m.name] = true
    end
    if not taken[base] then
        return base
    end
    local i = 2
    while taken[base .. " " .. i] do
        i = i + 1
    end
    return base .. " " .. i
end

local function commitRing(ring, markerName)
    local base = ADG:getWayPointsCount()
    local n = #ring
    local wayPoints = {}

    for i = 1, n do
        local p = ring[i]
        local prevId = base + (((i - 2) % n) + 1)
        local nextId = base + ((i % n) + 1)
        wayPoints[i] = {
            id = base + i,
            x = p.x,
            y = AD:getTerrainHeightAtWorldPos(p.x, p.z),
            z = p.z,
            -- two-way: each neighbour appears in both lists
            out = { prevId, nextId },
            incoming = { prevId, nextId },
            flags = ADFieldLoops.FLAG_SUBPRIO + ADFieldLoops.FLAG_OWNED,
        }
    end

    local markers = {}
    if markerName then
        local anchor, anchorDist = nearestForeignWaypoint(ring)
        local idx = 1
        if anchor then
            for i = 1, n do
                if ring[i] == anchor then
                    idx = i
                    break
                end
            end
        end
        markers[1] = { id = base + idx, name = uniqueMarkerName(markerName) }
        if anchor then
            say("marker '%s' placed on the ring point nearest your existing network (%.0f m away)",
                markers[1].name, anchorDist)
        end
    end

    ADCreate.sendEvent(wayPoints, markers)
    return n
end

-- ---------------------------------------------------------------- field lookup

local function refPosition()
    local veh = nil
    if ROOT.g_localPlayer ~= nil and ROOT.g_localPlayer.getCurrentVehicle ~= nil then
        veh = ROOT.g_localPlayer:getCurrentVehicle()
    end
    if type(veh) == "table" and veh.rootNode ~= nil then
        return ROOT.getWorldTranslation(veh.rootNode)
    end
    if ROOT.g_localPlayer ~= nil and ROOT.g_localPlayer.rootNode ~= nil then
        return ROOT.getWorldTranslation(ROOT.g_localPlayer.rootNode)
    end
    if ROOT.g_localPlayer ~= nil and ROOT.g_localPlayer.getPosition ~= nil then
        return ROOT.g_localPlayer:getPosition()
    end
    return nil
end

local function fieldAt(x, z)
    local farmland = ROOT.g_farmlandManager:getFarmlandAtWorldPosition(x, z)
    if farmland ~= nil and farmland.getField ~= nil then
        return farmland:getField()
    end
    return nil
end

local function parseArgs(a, b, c)
    local offset = tonumber(a) or ADFieldLoops.OFFSET
    local spacing = tonumber(b) or ADFieldLoops.SPACING
    local mode = (c or "map"):lower()
    if mode ~= "map" and mode ~= "scan" then
        mode = "map"
    end
    -- offset is deliberately unclamped: 0 sits on the boundary, negative rings outside it
    spacing = math.max(1, math.min(50, spacing))
    return offset, spacing, mode
end

-- ---------------------------------------------------------------- commands

function ADFieldLoops:generateHere(a, b, c)
    local ok, why = isReady()
    if not ok then
        return say(why)
    end
    local offset, spacing, mode = parseArgs(a, b, c)

    local x, _, z = refPosition()
    if x == nil then
        return say("could not work out where you are")
    end

    local poly, err
    if mode == "scan" then
        say("scanning ground from %.0f / %.0f at %.1f m resolution, this may take a moment...", x, z, ADFieldLoops.SCAN_RES)
        poly, err = polygonFromScan(x, z)
    else
        local field = fieldAt(x, z)
        if field == nil then
            return say("no field here. Stand inside a field, or use mode 'scan'.")
        end
        poly = polygonFromMap(field)
        err = "this field has no density map polygon, try mode 'scan'"
    end
    if poly == nil then
        return say("failed: %s", err or "no boundary found")
    end

    local ring, rerr = buildRing(poly, offset, spacing)
    if ring == nil then
        return say("failed: %s", rerr)
    end

    local field = fieldAt(x, z)
    local name = "Field " .. (field ~= nil and field:getId() or "?")
    local n = commitRing(ring, name)
    return say("created a two-way ring of %d waypoints, %.0f m in from the boundary, %.0f m spacing (%s mode)",
        n, offset, spacing, mode)
end

function ADFieldLoops:generateAll(a, b, c)
    local ok, why = isReady()
    if not ok then
        return say(why)
    end
    local offset, spacing, mode = parseArgs(a, b, c)
    if mode == "scan" then
        return say("'scan' mode is far too slow for every field at once. Use it per field with adfl.")
    end

    local made, skipped = 0, 0
    for _, field in pairs(ROOT.g_fieldManager:getFields()) do
        local poly = polygonFromMap(field)
        local ring = poly ~= nil and buildRing(poly, offset, spacing) or nil
        if ring ~= nil then
            commitRing(ring, "Field " .. field:getId())
            made = made + 1
        else
            skipped = skipped + 1
        end
    end
    return say("generated rings for %d fields, skipped %d (too small or too narrow for a %.0f m offset)",
        made, skipped, offset)
end

local function deleteWaypoints(list)
    if #list == 0 then
        return 0
    end
    local ids = {}
    for _, wp in ipairs(list) do
        ids[#ids + 1] = wp.id
    end
    -- descending, because every deletion renumbers everything above it
    table.sort(ids, function(p, q) return p > q end)
    ADDelete.sendEvent(ids)
    return #ids
end

function ADFieldLoops:removeHere()
    local ok, why = isReady()
    if not ok then
        return say(why)
    end
    local x, _, z = refPosition()
    if x == nil then
        return say("could not work out where you are")
    end
    local field = fieldAt(x, z)
    if field == nil then
        return say("no field here")
    end
    local poly = polygonFromMap(field)
    if poly == nil then
        return say("no boundary for this field, use adflRemoveAll if you have to")
    end

    local doomed = {}
    for _, wp in ipairs(ownedWaypoints()) do
        if pointInPolygon(wp.x, wp.z, poly) then
            doomed[#doomed + 1] = wp
        end
    end
    local n = deleteWaypoints(doomed)
    return say("removed %d generated waypoints inside field %s", n, tostring(field:getId()))
end

function ADFieldLoops:removeAll()
    local ok, why = isReady()
    if not ok then
        return say(why)
    end
    local n = deleteWaypoints(ownedWaypoints())
    return say("removed %d generated waypoints. Hand-recorded routes were not touched.", n)
end

function ADFieldLoops:refreshHere(a, b, c)
    local ok, why = isReady()
    if not ok then
        return say(why)
    end
    self:removeHere()
    return self:generateHere(a, b, c)
end

function ADFieldLoops:info()
    local ok, why = isReady()
    if not ok then
        return say(why)
    end
    local x, _, z = refPosition()
    if x == nil then
        return say("could not work out where you are")
    end
    local field = fieldAt(x, z)
    local onGround = isFieldGround(x, z)
    say("position %.0f / %.0f", x, z)
    say("farmland field here: %s", field ~= nil and tostring(field:getId()) or "none")
    say("ground under you is field ground: %s", tostring(onGround))
    say("AutoDrive graph: %d waypoints, %d of them generated by this mod",
        ADG:getWayPointsCount(), #ownedWaypoints())
    if field ~= nil then
        local poly = polygonFromMap(field)
        say("surveyed boundary: %s vertices", poly ~= nil and tostring(#poly) or "unavailable")
    end
    return ""
end

function ADFieldLoops:diag()
    local mine = getfenv(1)
    say("--- environment probe ---")
    say("this mod's env: AutoDrive=%s ADGraphManager=%s", type(mine.AutoDrive), type(mine.ADGraphManager))
    say("root global table: AutoDrive=%s ADGraphManager=%s", type(ROOT.AutoDrive), type(ROOT.ADGraphManager))

    for i, route in ipairs(accessRoutes()) do
        local ok, value = pcall(route.get)
        if not ok then
            say("%d. %s -> errored", i, route.label)
        elseif value == nil then
            say("%d. %s -> nil", i, route.label)
        else
            local env = envFromValue(value)
            say("%d. %s -> %s, env %s", i, route.label, type(value), env ~= nil and "FOUND" or "no")
        end
    end

    say("--- managers present ---")
    say("g_specializationManager=%s g_placeableSpecializationManager=%s g_vehicleTypeManager=%s g_modManager=%s",
        type(ROOT.g_specializationManager), type(ROOT.g_placeableSpecializationManager),
        type(ROOT.g_vehicleTypeManager), type(ROOT.g_modManager))
    local sm = ROOT.g_specializationManager
    if type(sm) == "table" then
        local names = {}
        pcall(function()
            for k in pairs(sm.specializations or {}) do
                if type(k) == "string" and k:find("AutoDrive") then
                    names[#names + 1] = k
                end
            end
        end)
        say("specializations matching 'AutoDrive': %s", #names > 0 and table.concat(names, ", ") or "none")
    end

    say("--- base game globals ---")
    say("g_currentMission=%s g_farmlandManager=%s g_fieldManager=%s FSDensityMapUtil=%s bit32=%s",
        type(ROOT.g_currentMission), type(ROOT.g_farmlandManager), type(ROOT.g_fieldManager),
        type(ROOT.FSDensityMapUtil), type(ROOT.bit32))

    local bound = bindAutoDrive()
    say("bind result: %s via %s", tostring(bound), tostring(ADFieldLoops.envName))
    return ""
end

addConsoleCommand("adflDiag", "Report where AutoDrive's script environment was found", "diag", ADFieldLoops)
addConsoleCommand("adfl","Ring route around the field you are in: adfl [offset] [spacing] [map|scan]", "generateHere", ADFieldLoops)
addConsoleCommand("adflAll", "Ring route around every field: adflAll [offset] [spacing]", "generateAll", ADFieldLoops)
addConsoleCommand("adflRefresh", "Rebuild the ring for the current field", "refreshHere", ADFieldLoops)
addConsoleCommand("adflRemove", "Remove the generated ring for the current field", "removeHere", ADFieldLoops)
addConsoleCommand("adflRemoveAll", "Remove every ring this mod generated", "removeAll", ADFieldLoops)
addConsoleCommand("adflInfo", "Report field and graph state where you are standing", "info", ADFieldLoops)
