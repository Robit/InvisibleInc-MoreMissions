local array = include( "modules/array" )
local binops = include( "modules/binary_ops" )
local util = include( "modules/util" )
local cdefs = include( "client_defs" )
local simdefs = include( "sim/simdefs" )
local unitdefs = include( "sim/unitdefs" )
local inventory = include( "sim/inventory" )
local simfactory = include( "sim/simfactory" )
local simquery = include( "sim/simquery" )
local mission_util = include( "sim/missions/mission_util" )
local escape_mission = include( "sim/missions/escape_mission" )
local SCRIPTS = include("client/story_scripts")
local mathutil = include( "modules/mathutil" )
local propdefs = include("sim/unitdefs/propdefs")

---------------------------------------------------------------------------------------------
-- Port of AI Terminal side mission from Worldgen Extended by wodzu93.
-- Design summary: Unlock AI terminal by opening four doors. Reward is either a new program slot for Incognita or upgrading an existing program!
-- Security measures: facility-wide blackout after you get the reward, all agents and enemies have limited vision. (Remember to fix hacked drones!) Knockout gas released into the objective starting with the terminal, guard investigates.
-- Functionality of adding new slot handled by Function Library.

-- Local helpers

local function queueCentral(script, scripts) --really informative huh
	script:queue( { type="clearOperatorMessage" } )
	for k, v in pairs(scripts) do
		script:queue( { script=v, type="newOperatorMessage" } )
		script:queue(0.5*cdefs.SECONDS)
	end	
end

local function findCell( sim, tag )
	local cells = sim:getCells( tag )
	return cells and cells[1]
end

local function CONSOLE_USED()
	return
	{
		trigger = simdefs.TRG_UNIT_HIJACKED,
		fn = function( sim, eventData )
			if eventData.unit and eventData.unit:hasTag("W93_INCOG_LOCK") then
				eventData.unit:removeTag("W93_INCOG_LOCK")
				return true
			end 
		end
	}
end

local function LOCK_DEACTIVATED()
	return
	{
		trigger = simdefs.TRG_UI_ACTION,
		fn = function( sim, eventData )
			if eventData.W93_incogLock then
				return true
			end 
		end
	}
end

local INCOGNITA_UPGRADED = {
	trigger = "activated_incogRoom",
	fn = function( sim, eventData )
		return eventData
	end
	}

local FINISHED_USING_TERMINAL = {
	trigger = "finished_using_AI_terminal",
	fn = function( sim, eventData )
		return true
	end,
}
----

-- AI TERMINAL NEW SLOT/PROGRAM UPGRADE BLOCK

-- The idea is to have a branching dialog that lets you choose between upgrading Incognita's slots and a program. This currently has Interactive Events as a dependency. Need to figure out why that is and fix it. Porting mission_util from IE by itself is not enough.
local function populateProgramList( sim )
	local player = sim:getPC()
	local programs = player:getAbilities()
	local options_list = {}
	local traits = {}
	-- for i, ability in pairs(programs) do
		-- if not ability.MM_upgraded then
			-- local name = ability.name
			-- table.insert( options_list, name )
			-- traits[name] = {}
			-- traits[name].parasite_strength = ability.parasite_strength or nil
			-- traits[name].break_firewalls = ability.break_firewalls or nil
			-- traits[name].maxCooldown = ability.maxCooldown or nil
			-- traits[name].value = ability.value or nil
			-- traits[name].cpu_cost = ability.cpu_cost or nil
			-- traits[name].ID = ability._abilityID
		-- end
	-- end
	
	for i = 1, #programs do
		local ability = programs[#programs +1 -i] --reverse iteration so the dialog buttons appear in the same order as in the slots
		if not ability.MM_upgraded then
			local name = ability.name
			table.insert( options_list, name )
			traits[name] = {}
			traits[name].parasite_strength = ability.parasite_strength or nil
			traits[name].break_firewalls = ability.break_firewalls or nil
			traits[name].maxCooldown = ability.maxCooldown or nil
			traits[name].value = ability.value or nil
			traits[name].cpu_cost = ability.cpu_cost or nil
			traits[name].ID = ability._abilityID
		end
	end	
	
	return {options_list = options_list, traits = traits}

end

local function upgradeIcebreak( upgradedProgram, sim, boost )
	local validUpgrade = false
	local result = (upgradedProgram.break_firewalls or 0) + boost
	if result > 0 then
		if (upgradedProgram.break_firewalls or 0) > 0 then
			validUpgrade = true
			upgradedProgram.break_firewalls = upgradedProgram.break_firewalls + boost
			
			upgradedProgram.MM_modifiers = upgradedProgram.MM_modifiers or {}
			upgradedProgram.MM_modifiers.break_firewalls = upgradedProgram.MM_modifiers.break_firewalls or 0
			upgradedProgram.MM_modifiers.break_firewalls = upgradedProgram.MM_modifiers.break_firewalls + boost
		end
	end
	local result2 = (upgradedProgram.parasite_strength or 0) + boost
	if result2 > 0 then
		if upgradedProgram.parasite_strength then
			validUpgrade = true
			upgradedProgram.parasite_strength = upgradedProgram.parasite_strength + boost
			
			upgradedProgram.MM_modifiers = upgradedProgram.MM_modifiers  or {}
			upgradedProgram.MM_modifiers.parasite_strength = upgradedProgram.MM_modifiers.parasite_strength or 0
			upgradedProgram.MM_modifiers.parasite_strength = upgradedProgram.MM_modifiers.parasite_strength + boost			
		end	
	end
	return validUpgrade
end

local function upgradePWRcost( upgradedProgram, sim, boost )
	local validUpgrade = false
	local result = (upgradedProgram.cpu_cost or 0) + boost
	if result > 0 then
		if upgradedProgram.cpu_cost then
			validUpgrade = true
			upgradedProgram.cpu_cost = upgradedProgram.cpu_cost + boost
			
			upgradedProgram.MM_modifiers = upgradedProgram.MM_modifiers  or {}
			upgradedProgram.MM_modifiers.cpu_cost = upgradedProgram.MM_modifiers.cpu_cost or 0
			upgradedProgram.MM_modifiers.cpu_cost = upgradedProgram.MM_modifiers.cpu_cost + boost			
		end
	end
	return validUpgrade
end

local function upgradeCooldown( upgradedProgram, sim, boost )
	local validUpgrade = false
	local result = (upgradedProgram.maxCooldown or 0 ) + boost
	if result > 0 then
		if upgradedProgram.maxCooldown then
			validUpgrade = true
			upgradedProgram.maxCooldown = upgradedProgram.maxCooldown + boost
			upgradedProgram.MM_modifiers = upgradedProgram.MM_modifiers  or {}
			upgradedProgram.MM_modifiers.maxCooldown = boost		
		end
	end
	return validUpgrade
end

local function upgradeRange( upgradedProgram, sim, boost )
	local validUpgrade = false
	local result = (upgradedProgram.range or 0) + boost
	if result > 0 then
		if upgradedProgram.range then
			validUpgrade = true
			upgradedProgram.range = upgradedProgram.range + boost
			upgradedProgram.MM_modifiers = upgradedProgram.MM_modifiers  or {}
			upgradedProgram.MM_modifiers.range = boost		
		end
	end
	return validUpgrade
end

local function finishProgramUpgrade( upgradedProgram, sim )
	upgradedProgram.value = upgradedProgram.value or 0
	upgradedProgram.value = upgradedProgram.value * 1.5 --increase resale value of upgraded program
	upgradedProgram.name = "UPGRADED "..upgradedProgram.name
	sim:getTags().used_AI_terminal = true
	sim:getTags().upgradedPrograms = true
	sim:triggerEvent( "finished_using_AI_terminal" )
end

local function upgradeDialog( script, sim )
-- Todo: improve text and descriptiveness of existing programs so the current program's selected parameter's current value is displayed in the dialog, for clarity
	while sim:getTags().used_AI_terminal == nil do

	local _, triggerData = script:waitFor( INCOGNITA_UPGRADED )
	-- local pronoun = STRINGS.GENDER_CONTEXT[unit:getUnitData().gender].he	
	
	local dialogPath = STRINGS.MOREMISSIONS.MISSIONS.AI_TERMINAL.DIALOG
	
	local txt = dialogPath.OPTIONS1_TXT
	local title = dialogPath.OPTIONS1_TITLE
	local options = dialogPath.OPTIONS1 --choose between slot and program upgrade
	
	if sim:getParams().agency.W93_aiTerminals and (sim:getParams().agency.W93_aiTerminals) >= 2 then --max slots reached
		options = dialogPath.OPTIONS1_MAXSLOTS
		txt = dialogPath.OPTIONS1_TXT_MAXSLOTS
	end

	option = mission_util.showDialog( sim, title, txt, options )
	
	if option == 3 then -- upgrade Incognita's slots
		mission_util.showGoodResult( sim, dialogPath.OPTIONS1_RESULT1_TITLE, dialogPath.OPTIONS1_RESULT1_TXT )
		sim:getTags().used_AI_terminal = true
		if not sim:getParams().agency.W93_aiTerminals or sim:getParams().agency.W93_aiTerminals < 2 then
			sim:getPC():getTraits().W93_incognitaUpgraded = 1
		end
		sim:triggerEvent( "finished_using_AI_terminal" )
		
	elseif option == 1 then
		option = nil
		triggerData.abort = true
	else--default to first and only option if max slots are reached
		local txt2 = dialogPath.OPTIONS2_TXT 
		
		local options2 = populateProgramList( sim ).options_list
		local option2 = mission_util.showDialog( sim, dialogPath.OPTIONS2_TITLE, txt2, options2 ) -- choose program to upgrade
		
		local program_name = options2[option2]
		
		for i = #options2, 1, -1 do
			if option2 == i then
				local txt3 = dialogPath.OPTIONS3_TXT
				local options3 = dialogPath.OPTIONS3
				-- {
					-- "Firewalls broken",
					-- "PWR cost",
					-- "Cooldown"
				-- }
	
				local program_ID  = populateProgramList(sim).traits[program_name].ID
				local upgradedProgram = sim:getPC():hasMainframeAbility( program_ID )
				
				if upgradedProgram.parasite_strength ~= nil then
					options3 = dialogPath.OPTIONS3_PARASITE
				end
				
				local option3 = mission_util.showDialog( sim, dialogPath.OPTIONS3_TITLE, txt3, options3 ) --choose between parameters to upgrade
				
				local txt_increment = dialogPath.OPTIONS4_TXT --"Choose a change. Parameter cannot be decreased below 1."
				
				local options_increment = dialogPath.OPTIONS4_INC --choose to increment or decrement
				-- {
					-- "Increase by 1",
					-- "Decrease by 1",
				-- }
				
				if option3 == 1 then
					--increase/decrease firewalls broken
					local txt_firewalls = util.sformat(dialogPath.FIREWALLS_TIP, upgradedProgram.name, (
					(((upgradedProgram.break_firewalls or 0) > 0) and upgradedProgram.break_firewalls )
					or (((upgradedProgram.parasite_strength or 0) > 0) and upgradedProgram.parasite_strength)
					or dialogPath.INVALID	))..txt_increment
					
					local option_firewalls = mission_util.showDialog( sim, dialogPath.OPTIONS_FIREWALLS_TITLE, txt_firewalls, options_increment )
					

					if option_firewalls == 3 then	
						local validUpgrade = upgradeIcebreak( upgradedProgram, sim, 1 )	
						if validUpgrade == true then
							mission_util.showGoodResult( sim, dialogPath.PROGRAM_UPGRADED_SUCCESS, dialogPath.OPTIONS_FIREWALLS_INCREASE )	
						
							finishProgramUpgrade(upgradedProgram, sim )
						else
							mission_util.showBadResult( sim, dialogPath.PROGRAM_UPGRADE_FAIL_TITLE, dialogPath.PROGRAM_UPGRADE_FAIL_TXT )
							option_firewalls = nil
							triggerData.abort = true
						end
						
					elseif option_firewalls == 2 then
						local validUpgrade = upgradeIcebreak( upgradedProgram, sim, -1 )
						if validUpgrade == true then
							mission_util.showGoodResult( sim, dialogPath.PROGRAM_UPGRADED_SUCCESS, dialogPath.OPTIONS_FIREWALLS_DECREASE )
						
							finishProgramUpgrade(upgradedProgram, sim )
						else
							mission_util.showBadResult( sim, dialogPath.PROGRAM_UPGRADE_FAIL_TITLE, dialogPath.PROGRAM_UPGRADE_FAIL_TXT )
							option_firewalls = nil
							triggerData.abort = true
						end
					else
						option_firewalls = nil
						triggerData.abort = true
					end
					
				elseif option3 == 2 then
				
					local txt_PWRcost = util.sformat(dialogPath.PWRCOST_TIP, upgradedProgram.name, (upgradedProgram.cpu_cost or dialogPath.INVALID))..txt_increment		

					if upgradedProgram.parasiteV2 then --blargh, hardcoding
						txt_PWRcost = util.sformat(dialogPath.PWRCOST_TIP, upgradedProgram.name, (dialogPath.INVALID))..txt_increment
					end
					
					local option_PWR = mission_util.showDialog( sim, dialogPath.OPTIONS_PWRCOST_TITLE, txt_PWRcost, options_increment )
					if option_PWR == 3 then
						
						local validUpgrade = upgradePWRcost( upgradedProgram, sim, 1 )
						if validUpgrade == true then
							mission_util.showGoodResult( sim, dialogPath.PROGRAM_UPGRADED_SUCCESS, dialogPath.OPTIONS_PWRCOST_INCREASE )					
							finishProgramUpgrade(upgradedProgram, sim )
						else
							mission_util.showBadResult( sim, dialogPath.PROGRAM_UPGRADE_FAIL_TITLE, dialogPath.PROGRAM_UPGRADE_FAIL_TXT )
							option_PWR = nil
							triggerData.abort = true						
						end
						
					elseif option_PWR == 2 then
					
						local validUpgrade = upgradePWRcost( upgradedProgram, sim, -1 )
						if validUpgrade == true then
							mission_util.showGoodResult( sim, dialogPath.PROGRAM_UPGRADED_SUCCESS, dialogPath.OPTIONS_PWRCOST_DECREASE )		
							finishProgramUpgrade(upgradedProgram, sim )
						else
							mission_util.showBadResult( sim, dialogPath.PROGRAM_UPGRADE_FAIL_TITLE, dialogPath.PROGRAM_UPGRADE_FAIL_TXT )
							option_PWR = nil
							triggerData.abort = true						
						end
					else
						option_PWR = nil
						triggerData.abort = true
					end
				elseif option3 == 3 then
				
					local txt_cooldown = util.sformat(dialogPath.COOLDOWN_TIP, upgradedProgram.name, (upgradedProgram.maxCooldown or dialogPath.INVALID))..txt_increment					
				
					local option_CD = mission_util.showDialog( sim, dialogPath.OPTIONS_COOLDOWN_TITLE, txt_cooldown, options_increment )
					if option_CD == 3 then
					
						local validUpgrade = upgradeCooldown( upgradedProgram, sim, 1 )
						if validUpgrade == true then
							mission_util.showGoodResult( sim, dialogPath.PROGRAM_UPGRADED_SUCCESS, dialogPath.OPTIONS_COOLDOWN_INCREASE )
							finishProgramUpgrade(upgradedProgram, sim )
						else
							mission_util.showBadResult( sim, dialogPath.PROGRAM_UPGRADE_FAIL_TITLE, dialogPath.PROGRAM_UPGRADE_FAIL_TXT )
							option_CD = nil
							triggerData.abort = true						
						end
						
					elseif option_CD == 2 then
					
						local validUpgrade = upgradeCooldown( upgradedProgram, sim, -1 )
						if validUpgrade == true then
							mission_util.showGoodResult( sim, dialogPath.PROGRAM_UPGRADED_SUCCESS, dialogPath.OPTIONS_COOLDOWN_DECREASE )	
							finishProgramUpgrade(upgradedProgram, sim )
						else
							mission_util.showBadResult( sim, dialogPath.PROGRAM_UPGRADE_FAIL_TITLE, dialogPath.PROGRAM_UPGRADE_FAIL_TXT )
							option_CD = nil
							triggerData.abort = true						
						end
					else
						option_CD = nil
						triggerData.abort = true
					end
				elseif option3 == 4 then
					local txt_range = util.sformat( dialogPath.RANGE_TIP, upgradedProgram.name, (upgradedProgram.range or dialogPath.INVALID))..txt_increment
					
					local option_RANGE = mission_util.showDialog( sim, dialogPath.OPTIONS_RANGE_TITLE, txt_range, options_increment )
					if option_RANGE == 3 then
						local validUpgrade = upgradeRange( upgradedProgram, sim, 1 )
						if validUpgrade == true then
							mission_util.showGoodResult( sim, dialogPath.PROGRAM_UPGRADED_SUCCESS, dialogPath.OPTIONS_RANGE_INCREASE )
							finishProgramUpgrade(upgradedProgram, sim )
						else
							mission_util.showBadResult( sim, dialogPath.PROGRAM_UPGRADE_FAIL_TITLE, dialogPath.PROGRAM_UPGRADE_FAIL_TXT )
							option_CD = nil
							triggerData.abort = true						
						end
					elseif option_RANGE == 2 then
						local validUpgrade = upgradeRange( upgradedProgram, sim, -1 )
						if validUpgrade == true then
							mission_util.showGoodResult( sim, dialogPath.PROGRAM_UPGRADED_SUCCESS, dialogPath.OPTIONS_RANGE_DECREASE )
							finishProgramUpgrade(upgradedProgram, sim )
						else
							mission_util.showBadResult( sim, dialogPath.PROGRAM_UPGRADE_FAIL_TITLE, dialogPath.PROGRAM_UPGRADE_FAIL_TXT )
							option_CD = nil
							triggerData.abort = true						
						end
					else
						option_CD = nil
						triggerData.abort = true
					end
				end
			end
		end
			
	end
	
	end
	
end

-- end of modal dialog stuff
----------------------------------------------------
-- Trigger Definitions

local function spottedDoor( script, sim )
	script:waitFor( mission_util.PC_SAW_CELL_WITH_TAG( script, "IncognitaLock2" ))
	local c = findCell( sim, "IncognitaLock2" )

	script:queue( 1*cdefs.SECONDS )
	script:queue( { type="pan", x=c.x, y=c.y } )
	script:queue( 0.1*cdefs.SECONDS )
	script:queue( { type="displayHUDInstruction", text=STRINGS.MOREMISSIONS.UI.INCOGROOM_TEXT1, x=c.x, y=c.y } )
	script:queue( { type="clearOperatorMessage" } )
	queueCentral( script, SCRIPTS.INGAME.AI_TERMINAL.CENTRAL_DOOR_SPOTTED ) 
	sim:removeObjective("find")
	sim:addObjective( STRINGS.MOREMISSIONS.MISSIONS.AI_TERMINAL.OBJECTIVE1, "upgrade_incognita1", 4 )
	script:waitFor( mission_util.PC_START_TURN )
	script:queue( { type="hideHUDInstruction" } )
end

local function incrementLocks( script, sim )
	local step = 0
	script:waitFor( LOCK_DEACTIVATED() )
	if sim:getPC():getTraits().W93_incogRoom_unlock and step ~= sim:getPC():getTraits().W93_incogRoom_unlock then
		sim:incrementTimedObjective( "upgrade_incognita1" )
		step = sim:getPC():getTraits().W93_incogRoom_unlock
	end
	if step >= 4 then
		for i, AIunit in pairs( sim:getAllUnits() ) do
			if AIunit:getName() == STRINGS.WORLDEXTEND.PROPS.INCOGROOM_AI_TERMINAL then
				AIunit:setPlayerOwner( sim:getPC() )
				sim:getCurrentPlayer():glimpseUnit( sim, AIunit:getID() )
				sim:dispatchEvent( simdefs.EV_UNIT_CAPTURE, { unit = AIunit, nosound = true } )	
			end
		end
		local c = findCell( sim, "IncognitaLock2" )
		for i, exit in pairs( c.exits ) do
			if exit.door and exit.locked and exit.keybits == simdefs.DOOR_KEYS.BLAST_DOOR then 
				sim:modifyExit( c, i, simdefs.EXITOP_UNLOCK )
				sim:modifyExit( c, i, simdefs.EXITOP_OPEN )
				sim:dispatchEvent( simdefs.EV_EXIT_MODIFIED, {cell=c, dir=i} )
				sim:getPC():glimpseExit( c.x, c.y, i )
			end
		end

		script:queue( 1*cdefs.SECONDS )
		script:queue( { type="pan", x=c.x, y=c.y } )
		script:queue( 0.1*cdefs.SECONDS )
		if sim:getTags().needPowerCells then
			queueCentral( script, SCRIPTS.INGAME.AI_TERMINAL.CENTRAL_UNLOCKED_MAINDOOR_OMNI_SEEN )
		else
			queueCentral( script, SCRIPTS.INGAME.AI_TERMINAL.CENTRAL_UNLOCKED_MAINDOOR_OMNI_UNSEEN )
		end
		script:queue( 5*cdefs.SECONDS )
		sim:removeObjective( "upgrade_incognita1" )
		sim:addObjective( STRINGS.MOREMISSIONS.MISSIONS.AI_TERMINAL.OBJECTIVE2, "upgrade_incognita2" )
	else
		script:addHook( incrementLocks )
	end
end

local function useConsole( script, sim )
	script:waitFor( CONSOLE_USED() )
	local c =  findCell( sim, "IncognitaLock1" )
	for i, exit in pairs( c.exits ) do
		if exit.door and exit.locked and exit.keybits == simdefs.DOOR_KEYS.BLAST_DOOR then 
			sim:modifyExit( c, i, simdefs.EXITOP_UNLOCK )
			sim:modifyExit( c, i, simdefs.EXITOP_OPEN )
			sim:dispatchEvent( simdefs.EV_EXIT_MODIFIED, {cell=c, dir=i} )
			sim:getPC():glimpseExit( c.x, c.y, i )

			script:queue( 1*cdefs.SECONDS )
			script:queue( { type="pan", x=c.x, y=c.y } )
			script:queue( 0.1*cdefs.SECONDS )
			queueCentral( script, SCRIPTS.INGAME.AI_TERMINAL.CENTRAL_UNLOCKED_SUBDOOR )
		end
	end

end

local function makeSmoke( script, sim ) 
	--IncogRoom fills with KO gas starting with main terminal, then the unlock terminals, then the doors. KO gas is harmless on first spawn then replaces itself with potent KO version, which replaces itself with harmless dispersal version (the last one is cosmetic only)
	local terminal
	for i, unit in pairs(sim:getAllUnits()) do
		if unit:getTraits().MM_incogRoom_main then
			terminal = unit
		end
	end
	local cell = sim:getCell(terminal:getLocation())
	local KOcloud = simfactory.createUnit( propdefs.MM_gas_cloud_harmless, sim ) -- will produce more toxic gas after 1 turn
	sim:spawnUnit( KOcloud )
	sim:warpUnit( KOcloud, cell )
	script:queue( { type="pan", x=cell.x, y=cell.y, zoom=0.27 } )
	queueCentral( script, SCRIPTS.INGAME.AI_TERMINAL.SMOKE_WARNING )
	sim:getNPC():spawnInterest(cell.x, cell.y, simdefs.SENSE_RADIO, simdefs.REASON_ALARMEDSAFE, terminal) 
	
	script:waitFor( mission_util.PC_START_TURN )
	
	for i, unit in pairs(sim:getAllUnits()) do
		if unit:getTraits().MM_incogRoom_unlock then
			local lock_cell = sim:getCell(unit:getLocation())
			local KOcloud = simfactory.createUnit( propdefs.MM_gas_cloud_harmless, sim )
			sim:spawnUnit( KOcloud )
			sim:warpUnit (KOcloud, lock_cell )
		end
	end
	
	script:waitFor( mission_util.PC_START_TURN )
	
	local obj_procGen = cell.procgenRoom
	local cells = {}
	sim:forEachCell(
	function( c )
		if c.procgenRoom == obj_procGen then
			for dir, exit in pairs( c.exits ) do
				if simquery.isDoorExit(exit) then
					table.insert( cells, c )
				end
			end
		end
	end )
	for i, doorcell in pairs( cells ) do
		local KOcloud = simfactory.createUnit( propdefs.MM_gas_cloud_harmless, sim )
		sim:spawnUnit( KOcloud )
		sim:warpUnit (KOcloud, doorcell )
	end	
end

local function upgradeIncognita( script, sim )
	-- local _, evData = script:waitFor( INCOGNITA_UPGRADED() )
	-- upgradeDialog( script, sim, agent )
	script:waitFor( FINISHED_USING_TERMINAL )
	script:queue( 1*cdefs.SECONDS )
	sim:removeObjective( "upgrade_incognita2" )
	if sim:getPC():getTraits().W93_incognitaUpgraded == 1 then
		queueCentral( script, SCRIPTS.INGAME.AI_TERMINAL.INCOGNITA_DATA_ACQUIRED )
	elseif sim:getTags().upgradedPrograms then
		queueCentral( script, SCRIPTS.INGAME.AI_TERMINAL.INCOGNITA_PROG_UPGRADED )
	-- else
		-- queueCentral( script, SCRIPTS.INGAME.AI_TERMINAL.INCOGNITA_TECH_ACQUIRED )	-- probably don't want this	
	end
	
	--now for the security measures
	script:queue( 1 * cdefs.SECONDS )
	script:addHook( makeSmoke )

	sim.exit_warning = nil
	sim.TA_mission_success = true

	if sim:getPC():getTraits().W93_incognitaUpgraded == 1 then
	
		script:waitFor( mission_util.PC_WON )
		if not sim:getParams().agency.W93_aiTerminals then
			sim:getParams().agency.W93_aiTerminals = 0
		end
		sim:getParams().agency.W93_aiTerminals = sim:getParams().agency.W93_aiTerminals + 1
		
	elseif sim:getTags().upgradedPrograms then
	
		script:waitFor( mission_util.PC_WON ) -- to think I could have been doing agency changes like wodzu all this time instead of putting things in DoFinishMission
		local agency = sim:getParams().agency
		agency.MM_upgradedPrograms = agency.MM_upgradedPrograms or {}
		
		local programs = sim:getPC():getAbilities()
		for i, ability in pairs(programs) do	
			-- local ID = ability._abilityID --see rant in scriptPath mainframe_abilities
			local ID = ability.name
			if ability.MM_modifiers then
				agency.MM_upgradedPrograms[ID] = {}
				agency.MM_upgradedPrograms[ID] = util.tcopy( ability.MM_modifiers )
			end
		end		
	end
end

local function addKeys( sim )

	local safeAdded = false
	local consoleAdded = false

	for i, unit in pairs(sim:getAllUnits()) do
		if unit:getTraits().safeUnit and not safeAdded then
			local item = simfactory.createUnit( propdefs.MM_W93_AiRoomPasscard, sim )
			sim:spawnUnit(item)
			unit:addChild(item)
			safeAdded = true
		end
		if unit:getTraits().mainframe_console and not consoleAdded then
			unit:addTag("W93_INCOG_LOCK")
			-- log:write("LOG console added!")
			consoleAdded = true
			if not (unit:getPlayerOwner() == sim:getNPC()) then
				-- log:write("reowning console")
				-- this is necessary on the 0 consoles setting because consoles start out player-owned
				unit:setPlayerOwner(sim:getNPC())
				unit:getTraits().hijacked = nil
				unit:getTraits().cpus = 2 --sorry, AndrewKay, I cannot be bothered to look up the console PWR determining thing for this
			end
		end
		if consoleAdded and safeAdded then
			break
		end
	end

end
---------------------------------------------------------------------------------------------
-- Begin!

local mission = class( escape_mission )

function mission:init( scriptMgr, sim )
	escape_mission.init( self, scriptMgr, sim )

	addKeys( sim )
	sim:addObjective( STRINGS.MOREMISSIONS.MISSIONS.AI_TERMINAL.OBJ_FIND, "find" )

	scriptMgr:addHook( "spottedDoor", spottedDoor )
	scriptMgr:addHook( "useConsole", useConsole )
	scriptMgr:addHook( "incrementLocks", incrementLocks )
	scriptMgr:addHook( "upgradeIncognita", upgradeIncognita )
	scriptMgr:addHook( "upgradeDialog", upgradeDialog )
	
	sim.exit_warning = STRINGS.MOREMISSIONS.MISSIONS.AI_TERMINAL.EXIT_WARNING

	--This picks a reaction rant from Central on exit
    local scriptfn = function()

        local scripts = SCRIPTS.INGAME.AI_TERMINAL.CENTRAL_JUDGEMENT.GOT_NOTHING
		if sim:getTags().upgradedPrograms then
			scripts = SCRIPTS.INGAME.AI_TERMINAL.CENTRAL_JUDGEMENT.GOT_UPGRADE
		elseif sim:getPC():getTraits().W93_incognitaUpgraded then
			scripts = SCRIPTS.INGAME.AI_TERMINAL.CENTRAL_JUDGEMENT.GOT_SLOT
		end
        local scr = scripts[sim:nextRand(1, #scripts)]
        return scr
    end	
	scriptMgr:addHook( "FINAL", mission_util.CreateCentralReaction(scriptfn))
end


function mission.pregeneratePrefabs( cxt, tagSet )
	escape_mission.pregeneratePrefabs( cxt, tagSet )
	table.insert( tagSet[1], "MM_incogRoom" )
end

function mission.generatePrefabs( cxt, candidates )
    local prefabs = include( "sim/prefabs" ) 
	escape_mission.generatePrefabs( cxt, candidates )
	
	if cxt.params.difficultyOptions.safesPerLevel == 0 then
		prefabs.generatePrefabs( cxt, candidates, "safe", 1 )
	end 
	if cxt.params.difficultyOptions.consolesPerLevel == 0 then
		prefabs.generatePrefabs( cxt, candidates, "console", 1 )
	end	
end	

return mission