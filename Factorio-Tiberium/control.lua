require("scripts/CnC_Walls") --Note, to make SonicWalls work / be passable
require("scripts/informatron/informatron_remote_interface")
local migration = require("__flib__.migration")

local tiberiumInternalName = "Factorio-Tiberium"  --No underscores for this one

local Beacon_Name = "growth-accelerator-beacon"
local Speed_Module_Name = "growth-accelerator-speed-module"

local TiberiumDamage = settings.startup["tiberium-damage"].value
local TiberiumGrowth = settings.startup["tiberium-growth"].value * 10
local TiberiumMaxPerTile = settings.startup["tiberium-growth"].value * 100 --Force 10:1 ratio with growth
local TiberiumRadius = 20 + settings.startup["tiberium-spread"].value * 0.4 --Translates to 20-60 range
local TiberiumSpread = settings.startup["tiberium-spread"].value
local bitersImmune = settings.startup["tiberium-wont-damage-biters"].value
local ItemDamageScale = settings.global["tiberium-item-damage-scale"].value
local debugText = settings.startup["tiberium-debug-text"].value
-- Starting items, if the option is ticked.
local tiberium_start = {
	["tiberium-centrifuge-3"] = 3,
	["iron-plate"] = 92,
	["copper-plate"] = 100,
	["transport-belt"] = 100,
	["underground-belt"] = 10,
	["splitter"] = 10,
	["burner-inserter"] = 20,
	["wooden-chest"] = 10,
	["small-electric-pole"] = 50,
	["stone-furnace"] = 1,
	["burner-mining-drill"] = 5,
	["boiler"] = 1,
	["steam-engine"] = 2,
	["pipe-to-ground"] = 20,
	["pipe"] = 20,
	["offshore-pump"] = 1
}

script.on_init(function()
	register_with_picker()
	global.tibGrowthNodeListIndex = 0
	global.tibGrowthNodeList = {}
	global.tibMineNodeListIndex = 0
	global.tibMineNodeList = {}
	global.tibDrills = {}
	global.tibOnEntityDestroyed = {}

	-- Each node should spawn tiberium once every 5 minutes (give or take a handful of ticks rounded when dividing)
	-- Currently allowing this to potentially update every tick but to keep things under control minUpdateInterval
	-- can be set to something greater than 1. When minUpdateInterval is reached the global tiberium growth rate
	-- will stagnate instead of increasing with each new node found but updates will continue to happen for all fields.
	global.minUpdateInterval = 1
	global.tiberiumTerrain = nil --"dirt-4" --Performance is awful, disabling this
	global.oreType = "tiberium-ore"
	global.tiberiumProducts = {global.oreType}
	global.damageForceName = "tiberium"
	if not game.forces[global.damageForceName] then
		game.create_force(global.damageForceName)
	end
	global.exemptDamageItems = {  -- List of prototypes that should not be damaged by growing Tiberium
		["mining-drill"] = true,
		["transport-belt"] = true,
		["underground-belt"] = true,
		["splitter"] = true,
		["wall"] = true,
		["pipe"] = true,
		["pipe-to-ground"] = true,
		["electric-pole"] = true,
		["inserter"] = true,
		["straight-rail"] = true,
		["curved-rail"] = true,
		["unit-spawner"] = true,  --Biters immune until both performance and evo factor are fixed
		["turret"] = true
	}
	
	-- Use interface to give starting items if possible
	if (settings.startup["tiberium-advanced-start"].value or settings.startup["tiberium-ore-removal"].value)
			and remote.interfaces["freeplay"] then
		local freeplayStartItems = remote.call("freeplay", "get_created_items") or {}
		for name, count in pairs(tiberium_start) do
			freeplayStartItems[name] = (freeplayStartItems[name] or 0) + count
		end
		remote.call("freeplay", "set_created_items", freeplayStartItems)
	end
	
	-- CnC SonicWalls Init
	CnC_SonicWall_OnInit(event)
	
	-- For drills that were present before Tiberium mod was added or converting from Beta save
	for _, surface in pairs(game.surfaces) do
		for _, drill in pairs(surface.find_entities_filtered{type = "mining-drill"}) do
			local fakeEvent = {}
			fakeEvent.entity = drill
			on_new_entity(fakeEvent)
		end
		local namedEntities = {"CnC_SonicWall_Hub", "node-harvester", "tib-spike", "growth-accelerator-node", "growth-accelerator"}
		for _, entity in pairs(surface.find_entities_filtered{name = namedEntities}) do
			local fakeEvent = {}
			fakeEvent.entity = entity
			fakeEvent.tick = game.tick
			on_new_entity(fakeEvent)
		end
		for _, node in pairs(surface.find_entities_filtered{name = "tibGrowthNode"}) do
			table.insert(global.tibGrowthNodeList, node)
		end
		for _, wall in pairs(surface.find_entities_filtered{name = "CnC_SonicWall_Wall"}) do
			wall.destroy()  --Wipe out all lingering SRF so we can rebuild them
		end
	end
	updateGrowthInterval()
	
	-- Define pack color for DiscoScience
	if remote.interfaces["DiscoScience"] and remote.interfaces["DiscoScience"]["setIngredientColor"] then
		remote.call("DiscoScience", "setIngredientColor", "tiberium-science", {r = 0.0, g = 1.0, b = 0.0})
	end
end)

function updateGrowthInterval()
	global.intervalBetweenNodeUpdates = math.floor(math.max(18000 / (#global.tibGrowthNodeList or 1), global.minUpdateInterval))
end

script.on_load(function()
	register_with_picker()
end)

function register_with_picker()
	--register to PickerExtended
	if remote.interfaces["picker"] and remote.interfaces["picker"]["dolly_moved_entity_id"] then
		script.on_event(remote.call("picker", "dolly_moved_entity_id"), OnEntityMoved)
	end
	--register to PickerDollies
	if remote.interfaces["PickerDollies"] and remote.interfaces["PickerDollies"]["dolly_moved_entity_id"] then
		script.on_event(remote.call("PickerDollies", "dolly_moved_entity_id"), OnEntityMoved)
	end
end

function OnEntityMoved(event)
	local entity = event.moved_entity
	if entity and (entity.name == "growth-accelerator") then
		local beacons = entity.surface.find_entities_filtered{name = Beacon_Name, position = event.start_pos}
		for _, beacon in pairs(beacons) do
			beacon.teleport(entity.position)
		end
	end
end

script.on_configuration_changed(function(data)
	if upgradingToVersion(data, tiberiumInternalName, "1.0.0") then
		game.print("Successfully ran conversion for "..tiberiumInternalName.." version 1.0.0")
		for _, surface in pairs(game.surfaces) do
			-- Registering entities for the base 0.18.28 change
			for _, entity in pairs(surface.find_entities_filtered{type = "mining-drill"}) do
				script.register_on_entity_destroyed(entity)
			end
			for _, entity in pairs(surface.find_entities_filtered{name = {"CnC_SonicWall_Hub", "tib-spike"}}) do
				script.register_on_entity_destroyed(entity)
			end
			-- Place Blossom trees on all the now bare nodes.
			for _, node in pairs(surface.find_entities_filtered{name = "tibGrowthNode"}) do
				createBlossomTree(surface, node.position)
			end
			-- Add invisible beacons for new growth accelerator speed researches
			for _, beacon in pairs(surface.find_entities_filtered{name = Beacon_Name}) do
				beacon.destroy()
			end
			for _, accelerator in pairs(surface.find_entities_filtered{name = "growth-accelerator"}) do
				local beacon = accelerator.surface.create_entity{name = Beacon_Name, position = accelerator.position, force = accelerator.force}
				beacon.destructible = false
				beacon.minable = false
				local module_count = accelerator.force.technologies["tiberium-growth-acceleration-acceleration"].level - 1
				UpdateBeaconSpeed(beacon, module_count)
			end
		end
		-- Unlock technologies that were split
		for _, force in pairs(game.forces) do
			if force.technologies["tiberium-processing-tech"].researched then
				force.technologies["tiberium-sludge-processing"].researched = true
			end
			if force.technologies["tiberium-power-tech"].researched then
				force.technologies["tiberium-sludge-recycling"].researched = true
			end
		end
	end
	
	if upgradingToVersion(data, tiberiumInternalName, "1.0.2") then
		if not global.tibOnEntityDestroyed then global.tibOnEntityDestroyed = {} end
		for _, surface in pairs(game.surfaces) do
			-- Registering entities correctly this time
			for _, entity in pairs(surface.find_entities_filtered{type = "mining-drill"}) do
				registerEntity(entity)
			end
			for _, entity in pairs(surface.find_entities_filtered{name = {"CnC_SonicWall_Hub", "tib-spike", "growth-accelerator-node", "growth-accelerator"}}) do
				registerEntity(entity)
			end
		end
		--Convert globals
		if not global.tibDrills then global.tibDrills = {} end
		for _, drill in pairs(global.drills or {}) do
			if drill.valid then
				table.insert(global.tibDrills, {entity = drill, name = drill.name, position = drill.position})
			end
		end
		global.drills = nil
		for _, charging in pairs(global.SRF_node_ticklist or {}) do
			charging.position = charging.emitter.position
		end
		for _, low in pairs(global.SRF_low_power_ticklist or {}) do
			low.position = low.emitter.position
		end
		local new_SRF_nodes = {}
		for _, node in pairs(global.SRF_nodes or {}) do
			local emitter = node.emitter or node  --Prevent issues when converting from Beta and changing versions
			table.insert(new_SRF_nodes, {emitter = emitter, position = emitter.position})
		end
		global.SRF_nodes = new_SRF_nodes
	end
	
	if upgradingToVersion(data, tiberiumInternalName, "1.0.5") then
		-- Define pack color for DiscoScience
		if remote.interfaces["DiscoScience"] and remote.interfaces["DiscoScience"]["setIngredientColor"] then
			remote.call("DiscoScience", "setIngredientColor", "tiberium-science", {r = 0.0, g = 1.0, b = 0.0})
		end
	end
	
	if upgradingToVersion(data, tiberiumInternalName, "1.0.7") then
		global.tiberiumProducts = {global.oreType}
	end
	
	if (data["mod_changes"]["Factorio-Tiberium"] and data["mod_changes"]["Factorio-Tiberium"]["new_version"]) and
			(data["mod_changes"]["Factorio-Tiberium-Beta"] and data["mod_changes"]["Factorio-Tiberium-Beta"]["old_version"]) then
		game.print("[Factorio-Tiberium] Successfully converted save from Beta Tiberium mod to Main Tiberium mod")
		game.print("> Found " .. #global.tibGrowthNodeList .. " nodes")
		game.print("> Found " .. #global.SRF_nodes .. " SRF hubs")
		game.print("> Found " .. #global.tibDrills .. " drills")
	end
	
	if upgradingToVersion(data, tiberiumInternalName, "1.0.8") then
		for _, surface in pairs(game.surfaces) do
			-- Destroy Blossom Trees with no nodes
			for _, blossom in pairs(surface.find_entities_filtered{name = "tibNode_tree"}) do
				if surface.count_entities_filtered{area = areaAroundPosition(blossom.position), name = "tibGrowthNode"} == 0 then
					game.print("destroyed tree at x: "..blossom.position.x.." y: "..blossom.position.y)
					blossom.destroy()
				end
			end
			-- Place Blossom Trees on all bare nodes
			for _, node in pairs(surface.find_entities_filtered{name = "tibGrowthNode"}) do
				if surface.count_entities_filtered{area = areaAroundPosition(node.position), name = "tibNode_tree"} == 0 then
					createBlossomTree(surface, node.position)
					game.print("created tree at x: "..node.position.x.." y: "..node.position.y)
				end
			end
		end
	end
end)

function upgradingToVersion(data, modName, version)
	if data["mod_changes"][modName] and data["mod_changes"][modName]["new_version"] then
		local otherModName  -- Can't use normal flib migration, because we want to support going from beta to main mod
		if modName == "Factorio-Tiberium" then
			otherModName = "Factorio-Tiberium-Beta"
		elseif modName == "Factorio-Tiberium-Beta" then
			otherModName = "Factorio-Tiberium"
		end
		local oldVersion = data["mod_changes"][modName]["old_version"] or 
				(data["mod_changes"][otherModName] and data["mod_changes"][otherModName]["old_version"])
		if not oldVersion then return false end
		local newVersion = data["mod_changes"][modName]["new_version"]
		oldVersion = migration.format_version(oldVersion, "%04d")
		newVersion = migration.format_version(newVersion, "%04d")
		version = migration.format_version(version, "%04d")
		return (oldVersion < version) and (newVersion >= version)
	end
	return false
end

function AddOre(surface, position, growthRate)
	local area = areaAroundPosition(position)
	local entities = surface.find_entities_filtered{area = area, name = "tiberium-ore"}

	if #entities >= 1 then
		oreEntity = entities[1]
		local newAmount = math.min(oreEntity.amount + growthRate, TiberiumMaxPerTile)
		if newAmount > oreEntity.amount then --Don't reduce ore amount when growing node
			oreEntity.amount = newAmount
		end
	elseif surface.count_entities_filtered{area = area, name = {"tibGrowthNode", "tibGrowthNode_infinite"}} > 0 then
		return false --Don't place ore on top of nodes
	else
		--Tiberium destroys all other non-Tiberium resources as it spreads
		local otherResources = surface.find_entities_filtered{area = area, type = "resource"}
		for _, entity in pairs(otherResources) do
			if (entity.name ~= "tiberium-ore") and (entity.name ~= "tibGrowthNode") and (entity.name ~= "tibGrowthNode_infinite") then
				entity.destroy()
			end
		end
		oreEntity = surface.create_entity{name = "tiberium-ore", amount = math.min(growthRate, TiberiumMaxPerTile), position = position}
		if global.tiberiumTerrain then 
			surface.set_tiles({{name = global.tiberiumTerrain, position = position}}, true, false)
		end
		surface.destroy_decoratives{position = position} --Remove decoration on tile on spread.
	end

	--Damage adjacent entities unless it's in the list of exemptDamageItems
	for _, entity in pairs(surface.find_entities(area)) do
		if entity.valid and not global.exemptDamageItems[entity.type] then
			if entity.type == "tree" then
				safeDamage(entity, 9999, game.forces.tiberium, "tiberium")
			else
				safeDamage(entity, TiberiumDamage, game.forces.tiberium, "tiberium")
			end
		end
	end

	return oreEntity
end

function CheckPoint(surface, position, lastValidPosition, growthRate)
	-- These checks are in roughly the order of guessed expense
	local tile = surface.get_tile(position)
	
	if not tile or not tile.valid then
		AddOre(surface, lastValidPosition, growthRate)
		return true
	end
	
	if tile.collides_with("resource-layer") then
		AddOre(surface, lastValidPosition, growthRate)
		return true  --Hit edge of water, add to previous ore
	end

	local area = areaAroundPosition(position)
	local entitiesBlockTiberium = {"CnC_SonicWall_Wall", "cliff", "tibGrowthNode_infinite"}
	if surface.count_entities_filtered{area = area, name = entitiesBlockTiberium} > 0 then
		AddOre(surface, lastValidPosition, growthRate * 0.5)  --50% lost
		return true  --Hit fence or cliff or spiked node, add to previous ore
	end
	
	local emitterHubs = surface.find_entities_filtered{area = area, name = "CnC_SonicWall_Hub"}
	for _, emitter in pairs(emitterHubs) do
		if emitter.valid then
			local emitterPowered = true
			for _, entry in pairs(global.SRF_node_ticklist or {}) do
				if emitter == entry.emitter then
					emitterPowered = false  -- Exclude nodes that haven't charged
					break
				end
			end
			if emitterPowered then  -- Only block if the SRF is powered
				AddOre(surface, lastValidPosition, growthRate * 0.5)  --50% lost
				return true  --Hit powered SRF emitter hub
			end
		end
	end
	
	if surface.count_entities_filtered{area = area, name = "tibGrowthNode"} > 0 then
		return false  --Don't grow on top of active node, keep going
	end
	
	if surface.count_entities_filtered{area = area, name = "tiberium-ore"} == 0 then
		AddOre(surface, position, growthRate)
		return true  --Reached edge of patch, place new ore
	else
		return false  --Not at edge of patch, keep going
	end
end

function PlaceOre(entity, howmany)
	--local timer = game.create_profiler()

	if not entity.valid then return end
	
	howmany = howmany or 1
	local surface = entity.surface
	local position = entity.position

	-- Scale growth rate based on distance from spawn
	local growthRate = TiberiumGrowth * math.max(1, math.sqrt(math.abs(position.x) + math.abs(position.y)) / 20)
			* math.max(1, TiberiumSpread / 50)
	-- Scale size based on distance from spawn, separate from density in case we end up wanting them to scale differently
	local size = TiberiumRadius * math.max(1, math.sqrt(math.abs(position.x) + math.abs(position.y)) / 30)

	local accelerator = surface.find_entity("growth-accelerator", position)
	if accelerator then
		howmany = howmany + accelerator.products_finished
		surface.create_entity{
			name = "growth-accelerator-text",
			position = {x = position.x - 1.5, y = position.y - 1},
			text = "Grew "..math.floor(accelerator.products_finished * growthRate).." extra ore",
			color = {r = 0, g = 204, b = 255},
		}
		accelerator.products_finished = 0
	end
	
	for n = 1, howmany do
		--Use polar coordinates to find a random angle and radius
		local angle = math.random() * 2 * math.pi
		local radius = 2.2 + math.sqrt(math.random()) * size -- A little over 2 to avoid putting too much on the node itself
	
		--Convert to cartesian and determine roughly how many tiles we travel through
		local dx = radius * math.cos(angle)
		local dy = radius * math.sin(angle)
		step = math.max(math.abs(dx), math.abs(dy))
		dx = dx / step
		dy = dy / step
		
		local lastValidPosition = position
		local x = position.x + dx
		local y = position.y + dx
		local i = 1
		--Check each tile along the line and stop when we've added ore one time
		while (i < step) do
			newPosition = {x = x, y = y}
			done = CheckPoint(surface, newPosition, lastValidPosition, growthRate)
			if done then break end
			
			lastValidPosition = newPosition
			x = x + dx
			y = y + dy
			i = i + 1
		end
		--Walked all the way to the end of the line, placing ore at the last valid position
		if not done then
			oreEntity = AddOre(surface, lastValidPosition, growthRate)
			--Spread setting makes spawning new nodes more likely
			if oreEntity and (math.random() < ((oreEntity.amount / TiberiumMaxPerTile) + (TiberiumSpread / 50 - 1))) then
				local nodeNames = {"tibGrowthNode", "tibGrowthNode_infinite"}
				if (surface.count_entities_filtered{position = newPosition, radius = TiberiumRadius * 0.8, name = nodeNames} == 0) then
					CreateNode(surface, newPosition)  --Use standard function to also remove overlapping ore
				end
			end
		end
	end

	-- Tell all mining drills to wake up
	for i, drill in pairs(global.tibDrills) do
		if drill.entity and drill.entity.valid then
			drill.entity.active = false
			drill.entity.active = true
			local control = drill.entity.get_control_behavior()
			if control then  --Toggle control behavior to force update to circuit network
				if control.resource_read_mode == defines.control_behavior.mining_drill.resource_read_mode.this_miner then
					control.resource_read_mode = defines.control_behavior.mining_drill.resource_read_mode.entire_patch
					control.resource_read_mode = defines.control_behavior.mining_drill.resource_read_mode.this_miner
				else
					control.resource_read_mode = defines.control_behavior.mining_drill.resource_read_mode.this_miner
					control.resource_read_mode = defines.control_behavior.mining_drill.resource_read_mode.entire_patch
				end
			end
		end
	end
	if debugText then
		game.print({"", timer, " end of place ore at ", position.x, ", ", position.y, "|", math.random()})
	end
end

function CreateNode(surface, position)
	local area = areaAroundPosition(position, 0.9)
	--Avoid overlapping with other nodes
	local nodeNames = {"tibGrowthNode", "tibGrowthNode_infinite"}
	if surface.count_entities_filtered{area = area, name = nodeNames} == 0 then
		--Clear other resources
		local ore = surface.find_entities_filtered{area = area, type = "resource"}
		for _, entity in pairs(ore) do
			if entity.valid then
				entity.destroy()
			end
		end
		--Aesthetic changes
		if global.tiberiumTerrain then
			local newTiles = {}
			local oldTiles = surface.find_tiles_filtered{area = area, collision_mask = "ground-tile"}
			for i, tile in pairs(oldTiles) do
				newTiles[i] = {name = global.tiberiumTerrain, position = tile.position}
			end
			surface.set_tiles(newTiles, true, false)
		end
		surface.destroy_decoratives{area = area}
		--Actual node creation
		local node = surface.create_entity{name="tibGrowthNode", position = position, amount = 15000}
		table.insert(global.tibGrowthNodeList, node)
		--Spawn tree entity when node is created
		createBlossomTree(surface, position)
		updateGrowthInterval()
	end
end

--Code for making the Liquid Seed spread tib
function TiberiumSeedMissile(surface, position, resource, amount)
	local radius = math.floor(amount^0.2)
	for x = position.x - radius*radius, position.x + radius*radius do
		for y = position.y - radius*radius, position.y + radius*radius do
			if ((x-position.x)*(x-position.x))+((y-position.y)*(y-position.y))<(radius*radius) then
				local intensity = math.floor(amount^0.9/radius - (position.x - x)^2 - (position.y - y)^2)
				if intensity > 0 then
					local placePos = {x = math.floor(x)+0.5, y = math.floor(y)+0.5}
					local oreEntity = surface.find_entity("tiberium-ore", placePos)
					local node = surface.find_entity("tibGrowthNode", placePos)
					local spike = surface.find_entity("tibGrowthNode_infinite", placePos)
					if spike then
					elseif node then
						node.amount = node.amount + intensity
					elseif oreEntity then
						oreEntity.amount = oreEntity.amount + intensity
					else
						local tile = surface.get_tile(placePos)
						if (not tile.collides_with("resource-layer")) then
							for _, ore in pairs(surface.find_entities_filtered{position = placePos, type = "resource"}) do
								ore.destroy()
							end
							surface.create_entity{name = resource, position = placePos, amount = intensity, enable_cliff_removal = false}
							--Cosmetic changes
							if global.tiberiumTerrain then 
								surface.set_tiles({{name = global.tiberiumTerrain, position = placePos}}, true, false)
							end
							surface.destroy_decoratives{position = placePos} --Remove decoration on tile on spread.
						end
					end
				end
			end
		end
	end
	local center = {x = math.floor(position.x) + 0.5, y = math.floor(position.y) + 0.5}
	local oreEntity = surface.find_entity("tiberium-ore", center)
	if oreEntity and (oreEntity.amount >= TiberiumMaxPerTile) then
		CreateNode(surface, center)
	end
end

script.on_event(defines.events.on_script_trigger_effect, function(event)
	--Liquid Seed trigger
	if event.effect_id == "seed-launch" then
		TiberiumSeedMissile(game.surfaces[event.surface_index], event.target_position, "tiberium-ore", TiberiumMaxPerTile)
		return
	end
end)

script.on_event(defines.events.on_resource_depleted, function(event)
	if event.entity.name == "tibGrowthNode" then
		--Remove tree entity when node is mined out
		removeBlossomTree(event.entity.surface, event.entity.position)
		removeNodeFromGrowthList(event.entity)
	end
end)

commands.add_command("tibNodeList",
	"Print the list of known Tiberium nodes",
	function()
		game.print("There are " .. #global.tibGrowthNodeList .. " nodes in the list")
		for i = 1, #global.tibGrowthNodeList do
			game.print("#"..i.." x:" .. global.tibGrowthNodeList[i].position.x .. " y:" .. global.tibGrowthNodeList[i].position.y)
		end
	end
)
commands.add_command("tibRebuildLists",
	"Update lists of mining drills and Tiberium nodes",
	function()
		global.tibGrowthNodeList = {}
		global.tibMineNodeList = {}
		global.SRF_nodes = {}
		global.tibDrills = {}
		for _, surface in pairs(game.surfaces) do
			for _, node in pairs(surface.find_entities_filtered{name = "tibGrowthNode"}) do
				table.insert(global.tibGrowthNodeList, node)
			end
			for _, srf in pairs(surface.find_entities_filtered{name = "CnC_SonicWall_Hub"}) do
				table.insert(global.SRF_nodes, {emitter = srf, position = srf.position})
			end
			for _, drill in pairs(surface.find_entities_filtered{type = "mining-drill"}) do
				table.insert(global.tibDrills, {entity = drill, name = drill.name, position = drill.position})
			end
		end
		updateGrowthInterval()
		game.print("Found " .. #global.tibGrowthNodeList .. " nodes")
		game.print("Found " .. #global.SRF_nodes .. " SRF hubs")
		game.print("Found " .. #global.tibDrills .. " drills")
	end
)
commands.add_command("tibGrowAllNodes",
	"Forces the mod to grow Tiberium ore at every node",
	function(invocationdata)
		local timer = game.create_profiler()
		local placements = tonumber(invocationdata["parameter"]) or 300
		game.print("There are " .. #global.tibGrowthNodeList .. " nodes in the list")
		for i = 1, #global.tibGrowthNodeList, 1 do
			if debugText then
				game.print("Growing node x:" .. global.tibGrowthNodeList[i].position.x .. " y:" .. global.tibGrowthNodeList[i].position.y)
			end
			PlaceOre(global.tibGrowthNodeList[i], placements)
		end
		game.print({"", timer, " end of tibGrowAllNodes"})
	end
)
commands.add_command("tibDeleteOre",
	"Deletes all the Tiberium ore on the map",
	function()
		for _, surface in pairs(game.surfaces) do
			for _, ore in pairs(surface.find_entities_filtered{name = "tiberium-ore"}) do
				ore.destroy()
			end
			-- Also destroy nodes if they aren't on valid terrain
			for _, node in pairs(surface.find_entities_filtered{name = {"tibGrowthNode", "tibGrowthNode_infinite"}}) do
				local tile = surface.find_tiles_filtered{position = node.position}[1]
				if tile.collides_with("resource-layer") then
					removeBlossomTree(surface, node.position)
					removeNodeFromGrowthList(node)
					node.destroy()
				end
			end
		end
	end
)
commands.add_command("tibChangeTerrain",
	"Changes terrain under Tiberium growths, can use internal name of any tile. Awful performance",
	function(invocationdata)
		local terrain = invocationdata["parameter"] or "dirt-4"
		--if not terrain then game.print("Not a valid tile name: "..terrain) break end
		global.tiberiumTerrain = terrain
		--Ore
		for _, surface in pairs(game.surfaces) do
			for _, ore in pairs(surface.find_entities_filtered{name = "tiberium-ore"}) do
				ore.surface.set_tiles({{name = terrain, position = ore.position}}, true, false)
			end
		end
		--Nodes
		for _, node in pairs(global.tibGrowthNodeList) do
			local position = node.position
			local area = areaAroundPosition(position, 1)
			local newTiles = {}
			local oldTiles = node.surface.find_tiles_filtered{area = area, collision_mask = "ground-tile"}
			for i, tile in pairs(oldTiles) do
				newTiles[i] = {name = terrain, position = tile.position}
			end
			node.surface.set_tiles(newTiles, true, false)
		end
	end
)
commands.add_command("tibFixMineLag",
	"Deletes all the deprecated Tiberium land mines on the map",
	function()
		for _, surface in pairs(game.surfaces) do
			for _, mine in pairs(surface.find_entities_filtered{name = "node-land-mine"}) do
				mine.destroy()
			end
		end
	end
)

--initial chunk scan
script.on_event(defines.events.on_chunk_generated, function(event)
	local surface = event.surface
	local area = {  -- Extra illegal, please don't report to Wube
		{event.area.left_top.x + 1, event.area.left_top.y + 1},
		{event.area.right_bottom.x - 1, event.area.right_bottom.y - 1}
	}
	for i, newNode in pairs(surface.find_entities_filtered{area = area, name = "tibGrowthNode"}) do
		table.insert(global.tibGrowthNodeList, newNode)
		local position = newNode.position
		--Spawn tree entity when node is placed
		createBlossomTree(surface, position)
		local howManyOre = math.min(math.max(10, (math.abs(position.x) + math.abs(position.y)) / 25), 200) --Start further nodes with more ore
		PlaceOre(newNode, howManyOre)
		--Cosmetic stuff
		local tileArea = areaAroundPosition(position, 0.9)
		surface.destroy_decoratives{area = tileArea}
		if global.tiberiumTerrain then
			local newTiles = {}
			local oldTiles = surface.find_tiles_filtered{area = tileArea, collision_mask = "ground-tile"}
			for i, tile in pairs(oldTiles) do
				newTiles[i] = {name = global.tiberiumTerrain, position = tile.position}
			end
			surface.set_tiles(newTiles, true, false)
		end
	end
	updateGrowthInterval()
end)

script.on_event(defines.events.on_tick, function(event)
	-- Update SRF Walls
	CnC_SonicWall_OnTick(event)
	-- Spawn ore check
	if (event.tick % global.intervalBetweenNodeUpdates == 0) then
		-- Step through the list of growth nodes, one each update
		local tibGrowthNodeCount = #global.tibGrowthNodeList
		global.tibGrowthNodeListIndex = global.tibGrowthNodeListIndex + 1
		if (global.tibGrowthNodeListIndex > tibGrowthNodeCount) then
			global.tibGrowthNodeListIndex = 1
		end
		if tibGrowthNodeCount >= 1 then
			PlaceOre(global.tibGrowthNodeList[global.tibGrowthNodeListIndex], 10)
		end
	end
	if not bitersImmune then
		local i = (event.tick % 60) + 1  --Loop through 1/60th of the nodes every tick
		while i <= #global.tibGrowthNodeList do
			local node = global.tibGrowthNodeList[i]
			if node.valid then
				local enemies = node.surface.find_entities_filtered{position = node.position, radius = TiberiumRadius, force = game.forces.enemy}
				for _, enemy in pairs(enemies) do
					safeDamage(enemy, TiberiumDamage * 6, game.forces.tiberium, "tiberium")
				end
			else
				game.print("Invalid Tiberium node in list position #"..i)
				game.print("Send save to Tiberium mod developers and then use /tibRebuildLists to fix it")
			end
			i = i + 60
		end
	end
end
)

script.on_nth_tick(10, function(event) --Player damage 6 times per second
	for _, player in pairs(game.connected_players) do
		if player.valid and player.character and player.character.valid then
			--MARV ore deletion
			if player.vehicle and (player.vehicle.name == "tiberium-marv") and (player.vehicle.get_driver() == player.character) then
				local deleted_ore = player.surface.find_entities_filtered{name = "tiberium-ore", position = player.position, radius = 4}
				local harvested_amount = 0
				for _, ore in pairs(deleted_ore) do
					harvested_amount = harvested_amount + ore.amount * 0.01
					ore.destroy()
				end
				if harvested_amount >= 1 then
					player.vehicle.insert{name = "tiberium-ore", count = math.floor(harvested_amount)}
				end
			end
			--Damage players that are standing on Tiberium Ore and not in vehicles
			local nearby_ore_count = player.surface.count_entities_filtered{name = "tiberium-ore", position = player.position, radius = 1.5}
			if nearby_ore_count > 0 and not player.character.vehicle and player.character.name ~= "jetpack-flying" then
				safeDamage(player, TiberiumDamage * nearby_ore_count * 0.1, game.forces.tiberium, "tiberium")
			end
			--Damage players with unsafe Tiberium products in their inventory
			local damagingItems = 0
			for _, inventory in pairs({player.get_inventory(defines.inventory.character_main), player.get_inventory(defines.inventory.character_trash)}) do
				if inventory and inventory.valid then
					for p = 1, #global.tiberiumProducts do
						damagingItems = damagingItems + inventory.get_item_count(global.tiberiumProducts[p])
						if damagingItems > 0 and not ItemDamageScale then break end
					end
				end
			end
			if damagingItems > 0 then
				if ItemDamageScale then
					safeDamage(player, math.ceil(damagingItems / 50) * TiberiumDamage * 0.3, game.forces.tiberium, "tiberium")	
				else
					safeDamage(player, TiberiumDamage * 0.3, game.forces.tiberium, "tiberium")
				end
			end
		end
	end
end)

function safeDamage(entityOrPlayer, damageAmount, damagingForce, damageType)
	if not entityOrPlayer.valid then return end
	local entity
	if entityOrPlayer.is_player() then
		if entityOrPlayer.character then
			entity = entityOrPlayer.character
		else
			return
		end
	else
		entity = entityOrPlayer
	end
	
	if entity.valid and entity.health and entity.health > 0 then
		entity.damage(damageAmount, damagingForce, damageType)
	end
end

function removeNodeFromGrowthList(node)
	for i = 1, #global.tibGrowthNodeList do
		if global.tibGrowthNodeList[i] == node then
			table.remove(global.tibGrowthNodeList, i)
			if global.tibGrowthNodeListIndex >= i then
				global.tibGrowthNodeListIndex = global.tibGrowthNodeListIndex - 1
			end
			return true
		end
	end
	return false
end

function areaAroundPosition(position, extraRange)  --Eventually add more checks to this
	if type(extraRange) ~= "number" then extraRange = 0 end
	return {
		{x = math.floor(position.x) - extraRange,     y = math.floor(position.y) - extraRange},
		{x = math.floor(position.x) + 1 + extraRange, y = math.floor(position.y) + 1 + extraRange}
	}
end

function validpairs(table, subscript)
	local function nextvalid(table, k)
		while true do
			k = next(table, k)
			if not k or not table[k] then
				return nil
			else
				if subscript and (type(table[k]) == "table") and table[k][subscript] then
					if table[k][subscript].valid then
						return k, table[k]
					end
				else
					if table[k].valid then
						return k, table[k]
					end
				end
			end
		end
	end
	return nextvalid, table, nil
end

script.on_nth_tick(60 * 300, function(event) --Global integrity check
	if event.tick == 0 then return end
	local nodeCount = 0
	for _, surface in pairs(game.surfaces) do
		nodeCount = nodeCount + surface.count_entities_filtered{name = "tibGrowthNode"}
	end
	if nodeCount ~= #global.tibGrowthNodeList then
		if debugText then
			game.print("!!!Warning: "..nodeCount.." Tiberium nodes exist while there are "..#global.tibGrowthNodeList.." nodes growing.")
			game.print("Rebuilding Tiberium node growth list.")
		end
		global.tibGrowthNodeList = {}
		for _, surface in pairs(game.surfaces) do
			for _, node in pairs(surface.find_entities_filtered{name = "tibGrowthNode"}) do
				table.insert(global.tibGrowthNodeList, node)
			end
		end
		updateGrowthInterval()
	end
end)

script.on_event(defines.events.on_trigger_created_entity, function(event)
	CnC_SonicWall_OnTriggerCreatedEntity(event)
	if debugText and event.entity.valid and (event.entity.name == "CnC_SonicWall_Wall-damage") then  --Checking when this is actually called
		game.print("SRF Wall damaged at "..event.entity.position.x..", "..event.entity.position.y)
	end
end)

function registerEntity(entity)  -- Cache relevant information to global and register
	local entityInfo = {}
	for _, property in pairs({"name", "type", "position", "surface", "force"}) do
		entityInfo[property] = entity[property]
	end
	local registration_number = script.register_on_entity_destroyed(entity)
	global.tibOnEntityDestroyed[registration_number] = entityInfo
end

function on_new_entity(event)
	local new_entity = event.created_entity or event.entity --Handle multiple event types
	local surface = new_entity.surface
	local position = new_entity.position
	local force = new_entity.force
	if (new_entity.type == "mining-drill") then
		registerEntity(new_entity)
		local duplicate = false
		for _, drill in pairs(global.tibDrills) do
			if drill.entity == new_entity then
				duplicate = true
				break
			end
		end
		if not duplicate then table.insert(global.tibDrills, {entity = new_entity, name = new_entity.name, position = position}) end
	end
	if (new_entity.name == "CnC_SonicWall_Hub") then
		registerEntity(new_entity)
		CnC_SonicWall_AddNode(new_entity, event.tick)
	elseif (new_entity.name == "node-harvester") then
		registerEntity(new_entity)
		--Remove tree entity when node is covered
		removeBlossomTree(surface, position)
	elseif (new_entity.name == "tib-spike") then
		registerEntity(new_entity)
		--Remove tree entity when node is covered
		removeBlossomTree(surface, position)
		local nodes = surface.find_entities_filtered{area = areaAroundPosition(position), name = "tibGrowthNode"}
		for _, node in pairs(nodes) do
			--Remove spiked node from growth list
			removeNodeFromGrowthList(node)
			local noderichness = node.amount
			node.destroy()
			surface.create_entity{
				name = "tibGrowthNode_infinite",
				position = position,
				force = neutral,
				amount = noderichness * 10,
				raise_built = true
			}
		end
		updateGrowthInterval()
	elseif (new_entity.name == "growth-accelerator-node") then
		new_entity.destroy()
		surface.create_entity{
			name = "growth-accelerator",
			position = position,
			force = force,
			raise_built = true
		}
	elseif (new_entity.name == "growth-accelerator") then
		registerEntity(new_entity)
		--Remove tree entity when node is covered
		removeBlossomTree(surface, position)
		if surface.count_entities_filtered{name = Beacon_Name, position = position} == 0 then
			local beacon = surface.create_entity{name = Beacon_Name, position = position, force = force}
			beacon.destructible = false
			beacon.minable = false
			local module_count = force.technologies["tiberium-growth-acceleration-acceleration"].level - 1
			UpdateBeaconSpeed(beacon, module_count)
		end
	end
end

script.on_event(defines.events.on_built_entity, on_new_entity)
script.on_event(defines.events.on_robot_built_entity, on_new_entity)
script.on_event(defines.events.script_raised_built, on_new_entity)
script.on_event(defines.events.script_raised_revive, on_new_entity)

function on_remove_entity(event)
	local entity = global.tibOnEntityDestroyed[event.registration_number]
	if not entity then return end
	local surface = entity.surface
	local position = entity.position
	if (entity.type == "mining-drill") then
		for i, drill in pairs(global.tibDrills) do
			if (drill.position.x == position.x) and (drill.position.y == position.y) and (drill.name == entity.name) then
				table.remove(global.tibDrills, i)
				break
			end
		end
	end
	if (entity.name == "CnC_SonicWall_Hub") then
		CnC_SonicWall_DeleteNode(entity, event.tick)
	elseif (entity.name == "tib-spike") then
		local area = areaAroundPosition(position)
		local nodes = surface.find_entities_filtered{area = area, name = "tibGrowthNode_infinite"}
		for _, node in pairs(nodes) do
			local spikedNodeRichness = node.amount
			node.destroy()
			local newNode = surface.create_entity{
				name = "tibGrowthNode",
				position = position,
				force = neutral,
				amount = math.floor(spikedNodeRichness / 10),
				raise_built = true
			}
			table.insert(global.tibGrowthNodeList, newNode)
			createBlossomTree(surface, position)
		end
		updateGrowthInterval()
	elseif (entity.name == "node-harvester") then
		--Spawn tree entity when node is uncovered
		createBlossomTree(surface, position)
	elseif (entity.name == "growth-accelerator") then
		--Spawn tree entity when node is uncovered
		createBlossomTree(surface, position)
		local beacons = surface.find_entities_filtered{name = Beacon_Name, position = position}
		for _, beacon in pairs(beacons) do
			beacon.destroy()
		end
	end
	global.tibOnEntityDestroyed[event.registration_number] = nil  -- Avoid this global growing forever
end

function createBlossomTree(surface, position)
	if surface.count_entities_filtered{area = areaAroundPosition(position), name = "tibGrowthNode"} > 0 then
		surface.create_entity{
			name = "tibNode_tree",
			position = position,
			force = neutral,
			raise_built = false
		}
	end
end

function removeBlossomTree(surface, position)
	for _, tree in pairs(surface.find_entities_filtered{area = areaAroundPosition(position), name = "tibNode_tree"}) do
		tree.destroy()
	end
end

script.on_event(defines.events.on_entity_destroyed, on_remove_entity)

-- Set modules in hidden beacons for Growth Accelerator speed bonus
function UpdateBeaconSpeed(beacon, total_modules)
	local module_inventory = beacon.get_module_inventory()
	if module_inventory then
		local added_modules = total_modules - module_inventory.get_item_count(Speed_Module_Name)
		if added_modules >= 1 then
			module_inventory.insert{name = Speed_Module_Name, count = added_modules}
		end
	end
end

function OnResearchFinished(event)
	-- TODO: delay execution when event.by_script == true
	local force = event.research.force
	if force and force.get_entity_count(Beacon_Name) > 0 then -- only update when beacons exist for force
		local module_count = force.technologies["tiberium-growth-acceleration-acceleration"].level - 1
		for _, surface in pairs(game.surfaces) do
			local beacons = surface.find_entities_filtered{name = Beacon_Name, force = force}
			for _, beacon in pairs(beacons) do
				UpdateBeaconSpeed(beacon, module_count)
				return
			end
		end
	end
end

script.on_event({defines.events.on_research_finished}, OnResearchFinished)

function OnForceReset(event)
	local force = event.force or event.destination
	if force and force.get_entity_count(Beacon_Name) > 0 then -- only update when beacons exist for force
		local module_count = force.technologies["tiberium-growth-acceleration-acceleration"].level - 1
		for _, surface in pairs(game.surfaces) do
			local beacons = surface.find_entities_filtered{name = Beacon_Name, force = force}
			for _, beacon in pairs(beacons) do
				UpdateBeaconSpeed(beacon, module_count)
			end
		end
	end
end

script.on_event({defines.events.on_technology_effects_reset, defines.events.on_forces_merging}, OnForceReset)

script.on_event(defines.events.on_player_created, function(event)
	local player = game.players[event.player_index]

	if settings.startup["tiberium-advanced-start"].value or settings.startup["tiberium-ore-removal"].value then
		if not remote.interfaces["freeplay"] then
			for name, count in pairs(tiberium_start) do
				player.insert{name = name, count = count}
			end
		end
		player.force.technologies["tiberium-mechanical-research"].researched = true
		player.force.technologies["tiberium-separation-tech"].researched = true
	end
end)
