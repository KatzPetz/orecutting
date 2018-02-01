orecutting = {}

orecutting.settings = {
	ore_distance = 2,
	player_distance = 80,
	dig_stone = true,

	on_new_process_hook = function(process) return true end,             -- do not start the process if set to nil or return false
	on_step_hook = function(process) return true end,                    -- if false is returned finish the process
	on_before_dig_hook = function(process, pos) return true end,         -- if false is returned the node is not digged
	on_after_dig_hook = function(process, pos, oldnode) return true end, -- if false is returned do nothing after digging node
}

local _orecutting_dig_stone = minetest.settings:get_bool("orecutting_dig_stone")
if _orecutting_dig_stone ~= nil then
	orecutting.settings.dig_stone = _orecutting_dig_stone
end

orecutting.ore_content_ids = {}
orecutting.stone_content_ids = {}
orecutting.process_runtime = {}

local orecutting_class = {}
orecutting_class.__index = orecutting_class

----------------------------
--- Constructor. Create a new process with template
----------------------------
function orecutting.new_process(playername, template)
	local process = setmetatable(template, orecutting_class)
	process.__index = orecutting_class
	process.orenodes_sorted = {} -- simple sortable list
	process.orenodes_hashed = {} -- With minetest.hash_node_position() as key for deduplication
	process.playername = playername
	process.ore_distance = process.ore_distance or orecutting.settings.ore_distance
	process.player_distance = process.player_distance or orecutting.settings.player_distance

	if process.dig_stone == nil then --bool value with default value true
		if orecutting.settings.dig_stone == nil then
			process.dig_stone = false
		else
			process.dig_stone = orecutting.settings.dig_stone
		end
	end

	local hook = orecutting.settings.on_new_process_hook(process)
	if hook == false then
		return
	end

	orecutting.process_runtime[playername] = process
	process = orecutting.get_process(playername) -- note: self is stored in inporcess table, but get_process function does additional data enrichments
	process:show_hud()
	process:process_cut_step()
	return process
end

----------------------------
-- Getter - get running process for player
----------------------------
function orecutting.get_process(playername)
	local process = orecutting.process_runtime[playername]
	if process then
		process._player = minetest.get_player_by_name(playername)
		if not process._player then
			-- stop process if player leaved the game
			process:stop_process()
			return
		end
	end
	return process
end

----------------------------------
--- Stop the orecutting process
----------------------------------
function orecutting_class:stop_process()
	if self._hud and self._player then
		self._player:hud_remove(self._hud)
	end
	orecutting.process_runtime[self.playername] = nil
end

----------------------------------
--- Add neighbors ore nodes to the list for further processing
----------------------------------
function orecutting_class:add_ore_neighbors(pos)
	-- read map around the node
	local vm = minetest.get_voxel_manip()
	local r_min = vector.subtract(pos, self.ore_distance)
	local r_max = vector.add(pos, self.ore_distance)
	local minp, maxp = vm:read_from_map(r_min, r_max)
	local area = VoxelArea:new({MinEdge = minp, MaxEdge = maxp})
	local data = vm:get_data()
	local orenodes_new = {}

	-- collect ore nodes to the lists
	for i in area:iterp(r_min, r_max) do
		local pos_ore = area:position(i)
		local poshash = minetest.hash_node_position(pos_ore)
		if not self.orenodes_hashed[poshash] then
			local ore_nodename = orecutting.ore_content_ids[data[i]]
			if ore_nodename and ore_nodename == self.ore_name then
				table.insert(self.orenodes_sorted, pos_ore)
				self.orenodes_hashed[poshash] = ore_nodename
				table.insert(orenodes_new, pos_ore)
			end
		end
	end

	-- collect stone
	if self.dig_stone then
		for _, pos_ore in ipairs(orenodes_new) do
			local minp = { x = math.min(pos.x, pos_ore.x),y = math.min(pos.y, pos_ore.y), z = math.min(pos.z, pos_ore.z) }
			local maxp = { x = math.max(pos.x, pos_ore.x),y = math.max(pos.y, pos_ore.y), z = math.max(pos.z, pos_ore.z) }

			for j in area:iterp(minp, maxp) do
				local stone_nodename = orecutting.stone_content_ids[data[j]]
				if stone_nodename then
					local pos_stone = area:position(j)
					local poshash = minetest.hash_node_position(pos_stone)
					if not self.orenodes_hashed[poshash] then
						if stone_nodename then
							table.insert(self.orenodes_sorted, pos_stone)
							self.orenodes_hashed[poshash] = stone_nodename
						end
					end
				end
			end
		end
	end
end

----------------------------------
--- Get the delay time before processing the node at pos
----------------------------------
function orecutting_class:get_delay_time(pos)
	local poshash = minetest.hash_node_position(pos)
	local nodedef = minetest.registered_nodes[self.orenodes_hashed[poshash]]
	local capabilities = self._player:get_wielded_item():get_tool_capabilities()
	local dig_params = minetest.get_dig_params(nodedef.groups, capabilities)
	if dig_params.diggable then
		return dig_params.time
	else
		-- try hand if the tool is not able to dig
		local dig_params = minetest.get_dig_params(nodedef.groups, minetest.registered_items[""].tool_capabilities)
		if dig_params.diggable then
			return dig_params.time
		end
	end
end

----------------------------------
--- Check node removal allowed
----------------------------------
function orecutting_class:check_processing_allowed(pos)
	return vector.distance(pos, self._player:get_pos()) < self.player_distance
end

----------------------------------
--- Select the next ore node for cutting
----------------------------------
function orecutting_class:select_next_ore_node()
	local playerpos = self._player:get_pos()
	-- sort the table for priorization higher nodes, select the first one and process them
	table.sort(self.orenodes_sorted, function(a,b)
		return vector.distance(a, playerpos) < vector.distance(b, playerpos)
	end)
	return self.orenodes_sorted[1]
end

----------------------------------
--- Process a cut step in minetest.after chain. Select a ore node and trigger processing for them
----------------------------------
function orecutting_class:process_cut_step()
	-- process the sneak toggle
	if self._player:get_player_control().sneak then
		if not self.sneak_pressed then
			-- sneak pressed second time - stop the work
			self:stop_process()
			return
		end
	else
		if self.sneak_pressed then
			self.sneak_pressed = false
		end
	end

	local function run_process_cut_step(playername)
		local process = orecutting.get_process(playername)
		if not process then
			return
		end

		local hook = orecutting.settings.on_step_hook(process)
		if hook == false then
			process:stop_process()
			return
		end

		local pos = process:select_next_ore_node()
		process:show_hud(pos)
		if pos then
			if process:check_processing_allowed(pos) then
				local delaytime = process:get_delay_time(pos)
				if delaytime then
					table.remove(process.orenodes_sorted, 1)
					process:cut_node(pos, delaytime)
				else
					-- wait for right tool is used, try again
					process:process_cut_step()
				end
			else
				-- just remove from hashed table and trigger the next step
				local poshash = minetest.hash_node_position(pos)
				table.remove(process.orenodes_sorted, 1)
				process.orenodes_hashed[poshash] = nil
				process:process_cut_step()
			end
		elseif next(process.orenodes_hashed) then
			-- nothing selected but still running. Trigger next step
			process:process_cut_step()
		else
			process:stop_process()
		end
	end
	minetest.after(0.1, run_process_cut_step, self.playername)
end

----------------------------
-- Process single node async
----------------------------
function orecutting_class:cut_node(pos, delay)
	local function run_cut_node(playername, pos)
		-- get current process object (async start)
		local process = orecutting.get_process(playername)
		if not process then
			return
		end

		-- Check it is async chain, trigger the next step in this case
		local poshash = minetest.hash_node_position(pos)
		if process.orenodes_hashed[poshash] then
			process:process_cut_step()
			process.orenodes_hashed[poshash] = nil
		end

		-- Check right node at the place before removal
		local node = minetest.get_node(pos)
		local id = minetest.get_content_id(node.name)
		if not (orecutting.ore_content_ids[id] or orecutting.stone_content_ids[id]) then
			return
		end

		local hook = orecutting.settings.on_before_dig_hook(process, pos)
		if hook == false then
			return
		end

		-- dig the node
		minetest.node_dig(pos, node, process._player)
	end
	minetest.after(delay, run_cut_node, self.playername, pos)
end

----------------------------------
--- Create hud message
----------------------------------
function orecutting_class:get_hud_message(pos)
	local message = "orecutting active for "..self.ore_name..". Hold sneak key to disable it"
	if pos then
		message = '['..#self.orenodes_sorted..'] '..minetest.pos_to_string(pos).." | "..message
	end
	return message

end

----------------------------------
--- Enable players hud message
----------------------------------
function orecutting_class:show_hud(pos)
	if not self._player then
		return
	end

	local message = self:get_hud_message(pos)

	if self._hud then
		self._player:hud_change(self._hud, "text", message)
	else
		self._hud = self._player:hud_add({
				hud_elem_type = "text",
				position = {x=0.3,y=0.3},
				alignment = {x=0,y=0},
				size = "",
				text = message,
				number = 0xFFFFFF,
				offset = {x=0, y=0},
			})
	end
end

----------------------------
-- dig node - check if orecutting and initialize the work
----------------------------
minetest.register_on_dignode(function(pos, oldnode, digger)
	-- check removed node is ore / check the digger is still online
	local id = minetest.get_content_id(oldnode.name)
	if not orecutting.ore_content_ids[id] or not digger then
		return
	end

	-- Get the process or create new one
	local playername = digger:get_player_name()
	local sneak = digger:get_player_control().sneak
	local process = orecutting.get_process(playername)
	if not process and sneak then
		process = orecutting.new_process(playername, {
			sneak_pressed = true, -- to control sneak toggle
			ore_name = oldnode.name,
		})
	end
	if not process then
		return
	end

	local hook = orecutting.settings.on_after_dig_hook(process, pos, oldnode)
	if hook == false then
		return
	end

	-- add the neighbors to the list.
	-- Note: The processing is started in new_process() using minetest.after() functionlity
	process:add_ore_neighbors(pos)
end)

----------------------------
-- start collecting infos about ores and stone after all mods loaded
----------------------------
minetest.after(0, function ()
	for _, ore in pairs(minetest.registered_ores) do
		if ore.wherein and ore.ore_type == "scatter" then
			local id = minetest.get_content_id(ore.ore)
			orecutting.ore_content_ids[id] = ore.ore
			if type(ore.wherein) == "table" then
				for _, v in ipairs(ore.wherein) do
					id = minetest.get_content_id(v)
					orecutting.stone_content_ids[id] = v
				end
			else
				id = minetest.get_content_id(ore.wherein)
				orecutting.stone_content_ids[id] = ore.wherein
			end
		end
	end
end)

----------------------------
-- Stop work if the player dies
----------------------------
minetest.register_on_dieplayer(function(player)
	local process = orecutting.get_process(player:get_player_name())
	if process then
		process:stop_process()
	end
end)

--dofile(minetest.get_modpath(minetest.get_current_modname()).."/hook_examples.lua")
