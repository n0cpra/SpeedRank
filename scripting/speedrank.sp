/*
		Proposed Changes
		1. Make a menu to show times.
		2. Function to see if the map has a course, and if not disable speedrank.
		3. Change from HookEntityOutPut to SDKHook?
		4. Possible need for bool IsValidTrigger(ent) to check if the trigger they touch is a speedrank trigger.
*/
#include <speedrank>

// Our Database!
Database
		dSpeedRank = null;
// Query Queue
Transaction
		TimeQue;

// ConVars, for uh ConVars
ConVar
		cHost, cAllowedClasses, cEnabled, cDebug;

// bIsSpeedRunning tells me if they are currently speed running or not. bCapSpeedRun is their toggle to turn off speed running (temp)
// bNoSteamID will tell me if we have their Steam ID or not.
bool
		bIsSpeedRunning[MAXPLAYERS+1], bCanSpeedRun[MAXPLAYERS+1], bNoSteamID[MAXPLAYERS+1], 
		jt = false, bPendingRecords = false, bTemp = true, bHasStart = false, 
		bHasEnd = false, bLate = false, bHasCourse = false, bCanUpdate[MAXPLAYERS+1] = false;

// Number of courses on the map.. iCourse[MAX_COURSES][MAX_CLASSES][MAX_RECORDS]
int
		iCourseCount = 0, iRunningCourse[MAXPLAYERS+1], QueIndex = 0, iRecords[MAX_COURSES][MAX_CLASSES],
		iButtons[MAXPLAYERS+1], iTotalRecords = 0;

// These hold the actual float values for the run/hud messages. Origin/Angles for course adding.
float
		fRunnerTimeStart[MAXPLAYERS+1], fRunnerTimeEnd[MAXPLAYERS+1], fTimes[MAX_COURSES][MAX_CLASSES][MAX_RECORDS],
		fOriginStart[3], fAnglesStart[3], fOriginEnd[3], fAnglesEnd[3];

// These are pretty obvious by the names?
char
		sSteamID[MAXPLAYERS+1], sMapName[MAX_NAME_LENGTH], cName[MAX_COURSES][MAX_CLASSES][MAX_RECORDS][MAX_NAME_LENGTH];

// tYourTime shows your current speed run time, tTimeToBeat shows what time you have left, tSpeedTimer[client] holds the timer handle.
Handle
		tYourTime, tTimeToBeat, tSpeedTimer[MAXPLAYERS+1];
Regex
		expr;
/******************************************************
					Forwards						  *
******************************************************/
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("speedrank");
	bLate = late;
	return APLRes_Success;
}
public void OnPluginStart()
{
	// JumpTools natives to show ammo/health regen, and various other things.
	if (LibraryExists("jumptools"))
	{
		jt = true;
		DebugLog("JumpTools detected. Will play nice.");
	}
	// ConVars
	CreateConVar("speedrank_version", PLUGIN_VERSION, "SpeedRank version", FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY);
	cEnabled = CreateConVar("speedrank_enabled", "1", "Turns SpeedRank on, or off.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cDebug = CreateConVar("speedrank_debug", "1", "Turns SpeedRank debugging on or off.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cAllowedClasses = CreateConVar("speedrank_class", "3", "Sets the classes that can speed run (1 Soldier, 2 DemoMan, 3 Engineers, " ...
									"4 All 3", FCVAR_NOTIFY, true, 1.0, true, 4.0);
	
	// Stops the timer, and cancels the speed run.
	RegConsoleCmd("sm_stoptimer", cmdStopTimer, "Stops your current speed run timer.");
	// Shows a menu with all the speed rank commands.
	RegConsoleCmd("sm_sr", cmdSRHelp, "Shows player commands");
	RegConsoleCmd("sm_speedrank", cmdSRHelp, "Shows player commands");
	
	// This displays admin menu.
	RegAdminCmd("sm_amenu", cmdAdminMenu, ADMFLAG_GENERIC);
	
	// Event hooks
	HookEvent("teamplay_round_start", eRoundStart, EventHookMode_PostNoCopy);
	HookEvent("player_changeclass", eEvents);
	HookEvent("player_team", eEvents);
	HookEvent("player_death", eEvents);
	HookEvent("player_teleported", eEvents);
	
	// ConVar hooks
	cEnabled.AddChangeHook(cEnabledChanged);
	cDebug.AddChangeHook(cDebugChanged);
	cAllowedClasses.AddChangeHook(cAllowedClassesChanged);
	
	// Hud Messages
	tYourTime = CreateHudSynchronizer();
	tTimeToBeat = CreateHudSynchronizer();
	
	// Hostname used for web stats.
	cHost = FindConVar("hostname");
	char host[64];
	cHost.GetString(host, sizeof host);
	
	// Hook entity output
	HookEntityOutput("trigger_multiple", "OnStartTouch", OnStartTouch);
}
public void OnPluginEnd()
{
	if (cEnabled.BoolValue)
	{
		// Save records on map change.
		for (int i = 1; i < MaxClients; i++)
		{
			bIsSpeedRunning[i] = false;
			bCanSpeedRun[i] = true;
		}
	}
	// Do we have record(s) pending?
	if (bPendingRecords)
	{
		SaveTimes();
	}
}
public void OnMapStart()
{
	if (cEnabled.BoolValue)
	{
		TimeQue = new Transaction();

		GetCurrentMap(sMapName, sizeof sMapName);
		// Let's precache some stuff.
		if (!IsModelPrecached(FROG)) { PrecacheModel(FROG, true); }
		if (!IsModelPrecached(TRIG_BOX)) { PrecacheModel(TRIG_BOX, true); }
		
		// Sounds
		PrecacheSound(RECORD_SOUND_B1, true);
		PrecacheSound(RECORD_SOUND_B2, true);
		PrecacheSound(RECORD_SOUND_B3, true);
		PrecacheSound(GJ_BASIC, true);
		PrecacheSound(DONOTFAIL, true);
		
		// Connect to our database.
		Database.Connect(OnDatabaseConnect, "speedrank");
		
		// Load the top 5 times
		CreateTimer(0.7, LoadMap);
	}
}
public void OnMapEnd()
{
	if (cEnabled.BoolValue)
	{
		// Do we have record(s) pending?
		if (bPendingRecords)
		{
			SaveTimes();
		}
	}
}
public void OnClientAuthorized(int client)
{
	if (cEnabled.BoolValue)
	{
		// Since we use steamid for player tracking only do stuff if we can get their id.
		if (GetClientAuthId(client, AuthId_Steam2, sSteamID[client], sizeof sSteamID))
		{
			GetPlayerProfile(client);
			bNoSteamID[client] = false;
			return;
		} else {
			CPrintToChat(client, "%s Unable to get Steam ID. SpeedRank is {dodgerblue}disabled{default} for you.");
			bNoSteamID[client] = true; bCanSpeedRun[client] = false; bNoSteamID[client] = true;
			return;
		}
	}
}
public void OnClientPutInServer(int client)
{
	if (cEnabled.BoolValue)
	{
		if (IsValidClient(client))
		{
			bIsSpeedRunning[client] = false;
			iRunningCourse[client] = 0;
			bCanSpeedRun[client] = true;
		}
	}
}
public void OnClientDisconnect(int client)
{
	if (cEnabled.BoolValue)
	{
		if (jt && bIsSpeedRunning[client]) { JT_EndSpeedRun(client); }
		if (tSpeedTimer[client] != INVALID_HANDLE) { delete tSpeedTimer[client]; }
		bIsSpeedRunning[client] = false;
		iRunningCourse[client] = 0;
		bCanSpeedRun[client] = true;
	}
}
/******************************************************
					Commands						  *
******************************************************/
public Action cmdStopTimer(int client, int args)
{
	if (bIsSpeedRunning[client])
	{
		if (jt)
		{
			JT_EndSpeedRun(client);
			JT_ReloadPlayerSettings(client);
		}
	}
	iRunningCourse[client] = 0;
	bIsSpeedRunning[client] = false;
	if (tSpeedTimer[client] != INVALID_HANDLE) { delete tSpeedTimer[client]; }
	return Plugin_Handled;
}
public Action cmdSRHelp(int client, int args)
{
	if (cEnabled.BoolValue)
	{
		Panel pPlayerMenu = new Panel();
		pPlayerMenu.SetTitle("-[ SpeedRank Commands ]-");
		pPlayerMenu.DrawItem(" ", ITEMDRAW_SPACER);
		pPlayerMenu.DrawItem("Show Soldier times.");
		pPlayerMenu.DrawItem("Show Demoman times.");
		pPlayerMenu.DrawItem("Show Engineer times.");
		pPlayerMenu.DrawItem("Toggle speed running");
		if (IsUserAdmin(client))
		{
			pPlayerMenu.DrawItem(" ", ITEMDRAW_SPACER);
			pPlayerMenu.DrawItem("Admin menu: !amenu");
		}
		pPlayerMenu.Send(client, cPlayerMenuHandler, 30);
		delete pPlayerMenu;
	}
	return Plugin_Handled;
}
public Action cmdAdminMenu(int client, int args)
{
	if (cEnabled.BoolValue)
	{
		Panel pAdminMenu = new Panel();
		pAdminMenu.SetTitle("-[ SpeedRank Admin ]-");
		pAdminMenu.DrawItem("Add Course Start", (bHasStart ? ITEMDRAW_DISABLED:ITEMDRAW_DEFAULT));
		pAdminMenu.DrawItem("Add Course End", (bHasEnd ? ITEMDRAW_DISABLED:ITEMDRAW_DEFAULT));
		pAdminMenu.DrawItem("Save Course", (bHasEnd ? ITEMDRAW_DEFAULT:ITEMDRAW_DISABLED));
		pAdminMenu.DrawItem("Reset", (bHasEnd ? ITEMDRAW_DEFAULT:ITEMDRAW_DISABLED));
		pAdminMenu.DrawItem("Delete a course", (bHasCourse ? ITEMDRAW_DEFAULT:ITEMDRAW_DISABLED));
		if (IsUserRoot(client))
		{
			pAdminMenu.DrawItem("ROOT Commands", ITEMDRAW_DISABLED);
			pAdminMenu.DrawItem("Reload Plugin");
			if (bTemp)
			{
				pAdminMenu.DrawItem("Disable SpeedRank until map change");
			} else {
				pAdminMenu.DrawItem("Enable SpeedRank");
			}
		}
		pAdminMenu.DrawItem("Exit");
		// Menu is forever so it makes adding courses easier, and faster.
		pAdminMenu.Send(client, cAdminMenuHandler, MENU_TIME_FOREVER);
		delete pAdminMenu;
	}
	return Plugin_Handled;
}
void cmdShowTop(int client, TFClassType class)
{
	switch (class)
	{
		case TFClass_Soldier:
		{
			for (int i=1;i<=iCourseCount+1;i++)
			{
				CPrintToChat(client, "%s -[ Course %i ]-", TAG2, i);
				for (int j=0;j<=2;j++)
				{
					if (!StrEqual(cName[i][3][j], ""))
					{
						CPrintToChat(client, "%s #%i %s [Course %i] [Time %s]", TAG2, j+1, cName[i][class][j], i, SpeedTime(fTimes[i][class][j]));
					}
				}
			}
		}
		case TFClass_DemoMan:
		{
			for (int i=1;i<=iCourseCount+1;i++)
			{
				CPrintToChat(client, "%s -[ Course %i ]-", TAG2, i);
				for (int j=0;j<=2;j++)
				{
					if (!StrEqual(cName[i][class][j], ""))
					{
						CPrintToChat(client, "%s #%i %s [Course %i] [Time %s]", TAG2, j+1, cName[i][class][j], i, SpeedTime(fTimes[i][class][j]));
					} 
				}
			}
		}
		case TFClass_Engineer:
		{
			for (int i=1;i<=iCourseCount+1;i++)
			{
				CPrintToChat(client, "%s -[ Course %i ]-", TAG2, i);
				for (int j=0;j<=2;j++)
				{
					if (!StrEqual(cName[i][class][j], ""))
					{
						CPrintToChat(client, "%s #%i %s [Course %i] [Time %s]", TAG2, j+1, cName[i][class][j], i, SpeedTime(fTimes[i][class][j]));
					}
				}
			}
		}
	}
}
/******************************************************
					Menu Callbacks					  *
******************************************************/
public int cPlayerMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		switch (param2)
		{
			case 2: { cmdShowTop(param1, TFClass_Soldier); }
			case 3: { cmdShowTop(param1, TFClass_DemoMan); }
			case 4: { cmdShowTop(param1, TFClass_Engineer); }
			case 5: { cmdDisableSpeedRuns(param1); }
			case 6: { cmdAdminMenu(param1, 0); }
		}
	}
}
public int cAdminMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		switch (param2)
		{
			case 1: { cmdAddCourseStart(param1); cmdAdminMenu(param1, 0); }
			case 2: { cmdAddCourseEnd(param1); cmdAdminMenu(param1, 0); }
			case 3: { cmdSaveCourse(param1); }
			case 4: { cmdResetCourse(param1); cmdAdminMenu(param1, 0); }
			case 5: { cmdShowCourses(param1); }
			case 6: { /* Skip it's used as a title (ITEMDRAW_DISABLED) */ }
			case 7: { cmdAdminMenu(param1, 0); }
			case 8: { cmdAdminDisableSpeedRuns(param1); cmdAdminMenu(param1, 0); }
		}
	} else if (action == MenuAction_Cancel)
	{
		// Will this close?
	}
}
public int cAdminDelMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	char query[100];
	dSpeedRank.Format(query, sizeof query, "DELETE FROM Courses WHERE CourseNumber = '%i' AND MapName = '%s'", param2, sMapName);
	dSpeedRank.Query(OnDeleteCourse, query, param1);
}
/******************************************************
					Admin Functions					  *
******************************************************/
void cmdResetCourse(int client)
{
	// If they have a start, and end point reset, or if they have a start point reset.
	if (bHasStart && bHasEnd || bHasStart)
	{
		bHasStart = false; bHasEnd = false;
		CPrintToChat(client, "%s You have reset the course.", TAG2);
	}
}
void cmdShowCourses(int client)
{
	char query[100];
	dSpeedRank.Format(query, sizeof query, "SELECT * FROM `Courses` WHERE MapName = '%s'", sMapName);
	dSpeedRank.Query(OnShowCourse, query, client);
}
void cmdAddCourseStart(int client)
{
	if (!IsClientInWorld(client))
	{
		CPrintToChat(client, "%s You need to be spawned in the world to add a start point.", TAG2);
		return;
	}
	
	GetClientAbsOrigin(client, fOriginStart);
	GetClientAbsAngles(client, fAnglesStart);
	
	bHasStart = true;
}
void cmdAddCourseEnd(int client)
{
	if (!IsClientInWorld(client))
	{
		CPrintToChat(client, "%s You need to be spawned in the world to add a end point.", TAG2);
		return;
	}
	
	GetClientAbsOrigin(client, fOriginEnd);
	GetClientAbsAngles(client, fAnglesEnd);

	bHasEnd = true;
}
void cmdSaveCourse(int client)
{	
	if (iCourseCount == 0) { iCourseCount = 1; } else { iCourseCount++; }

	CreateModels(iCourseCount, fOriginStart, fAnglesStart, true);
	CreateModels(iCourseCount, fOriginEnd, fAnglesEnd, false);
	
	bHasStart = false; bHasEnd = false;
	
	char query[1024];
	dSpeedRank.Format(query, sizeof query, "INSERT INTO `Courses` VALUES(null, '%i','%s','%f','%f','%f','%f','%f','%f','%f','%f');", 
		iCourseCount, sMapName, fOriginStart[0], fOriginStart[1], fOriginStart[2], fAnglesStart[1], 
		fOriginEnd[0], fOriginEnd[1], fOriginEnd[2], fAnglesEnd[1]);
	dSpeedRank.Query(OnSavedCourse, query, client);
	
	CPrintToChat(client, "%s You have saved course {dodgerblue}Course %i{default}", TAG2, iCourseCount); bHasCourse = true;
	
	if (cDebug.BoolValue)
	{
		DebugLog("Course %i added by %N", iCourseCount, client);
		DebugLog("Course %i Start Point (%f %f %f) Angle: (%f)", iCourseCount, fOriginStart[0], fOriginStart[1], fOriginStart[2], fAnglesStart[1]);
		DebugLog("Course %i End Point (%f %f %f) Angle: (%f)", iCourseCount, fOriginEnd[0], fOriginEnd[1], fOriginEnd[2], fAnglesEnd[1]);
		DebugLog("Courses on this map: %i", iCourseCount);
	}
}
void cmdAdminDisableSpeedRuns(int client)
{
	if (bTemp)
		bTemp = false;
	else
		bTemp = true;
	CPrintToChatAll("%s has been {dodgerblue}%s{normal} ", TAG2, (bTemp ? "Enabled":"Disabled"));
	if (cDebug.BoolValue) { DebugLog("%N has %s speed running for this map.", client, (bTemp ? "Enabled":"Disabled")); }
}
/******************************************************
					  Functions						  *
******************************************************/
int GetCourseCount()
{
	int entity, count = 0;
	char name[MAX_NAME_LENGTH];
	while ((entity = FindEntityByClassname(entity, "prop_dynamic")) != -1)
	{
		GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof name);
		if (StrContains(name, "CourseStart", false) != -1)
		{
			count++;
			DebugLog("Entity %i Name %s", entity, name);
		}
	}
	if (count == 0) { bTemp = false; }
	if (cDebug.BoolValue) { DebugLog("Found %i Course(s) on %s.", count, sMapName); }
	return count;
}
void DebugLog(char[] text, any ...)
{
	char path[PLATFORM_MAX_PATH], date[32], time[32];

	FormatTime(date, sizeof date, "%m-%d-%y", GetTime());
	FormatTime(time, sizeof time, "%I:%M:%S", GetTime());
	BuildPath(Path_SM, path, PLATFORM_MAX_PATH, "logs/Speedrank-Log-%s.log", date);

	int len = strlen(text) + 255;
	char[] text2 = new char[len];
	VFormat(text2, len, text, 2);
	PrintToServer("%s %s", time, text2);

	if (!FileExists(path))
	{
		File log = OpenFile(path, "w");
		log.WriteLine("----- SpeedRank log [Time:%s] [Date:%s] -----" , time, date);
		log.WriteLine("[%s] %s", time, text2);
		log.Close();
	} else {
		File log = OpenFile(path, "a");
		log.WriteLine("[%s] %s", time, text2);
		log.Close();
	}
}
bool IsClientInWorld(int client)
{
	TFTeam team = TF2_GetClientTeam(client);
	if (team == TFTeam_Spectator || team == TFTeam_Unassigned) return false;
	return true;
}
int GetCourseNumber(char[] str)
{
	// This should never happen, but it is and I don't know why.
	if (StrEqual(str, "", false)) { return 0; }
	char match[128];
	
	expr = CompileRegex("([0-9])", PCRE_CASELESS);
	if (expr.Match(str) >= 1)
	{
		if (expr.GetSubString(0, match, sizeof(match)))
		{
			
		}
	}
	delete expr;
	return StringToInt(match);
}
void cmdDisableSpeedRuns(int client)
{
	if (bCanSpeedRun[client])
		bCanSpeedRun[client] = false;
	else
		bCanSpeedRun[client] = true;
	CPrintToChat(client, "%s You have {dodgerblue}%s{normal} speed running.", TAG2, (bCanSpeedRun[client] ? "Enabled":"Disabled"));
}
char GetPlayerClass(int client)
{
	char buffer[MAX_NAME_LENGTH];
	if (IsValidClient(client))
	{
		TFClassType class = TF2_GetPlayerClass(client);
		switch (class)
		{
			case TFClass_Scout: { Format(buffer, sizeof(buffer), "Scout"); }
			case TFClass_Sniper: { Format(buffer, sizeof(buffer), "Sniper"); }
			case TFClass_Soldier: { Format(buffer, sizeof(buffer), "Soldier"); }
			case TFClass_DemoMan: { Format(buffer, sizeof(buffer), "Demoman"); }
			case TFClass_Medic: { Format(buffer, sizeof(buffer), "Medic"); }
			case TFClass_Heavy: { Format(buffer, sizeof(buffer), "Heavy"); }
			case TFClass_Pyro: { Format(buffer, sizeof(buffer), "Pyro"); }
			case TFClass_Spy: { Format(buffer, sizeof(buffer), "Spy"); }
			case TFClass_Engineer: { Format(buffer, sizeof(buffer), "Engineer"); }
			default: { Format(buffer, sizeof(buffer), "Unknown"); }
		}
	}
	return buffer;
}
void CreateModels(int course_num, float[3] course_orig, float[3] course_ang, bool IsStart)
{
	int EntFrog = CreateEntityByName("prop_dynamic");
	char frgName[MAX_NAME_LENGTH];
	
	if (IsValidEntity(EntFrog))
	{
		SetEntityModel(EntFrog, FROG);
		SetEntProp(EntFrog, Prop_Data, "m_CollisionGroup", 0);
		SetEntProp(EntFrog, Prop_Data, "m_nSolidType", 6);
		DispatchSpawn(EntFrog);
		Format(frgName, sizeof frgName, "Course%s%i", (IsStart ? "Start":"End"), course_num);
		DispatchKeyValue(EntFrog, "targetname", frgName);
		TeleportEntity(EntFrog, course_orig, course_ang, NULL_VECTOR);
		if (cDebug.BoolValue)
		{
			DebugLog("Creating model %s Point (%f %f %f) Angle: (%f) for course # %i", (IsStart ? "Start":"End"), course_orig[0], course_orig[1], course_orig[2], course_ang[1], course_num);
		}
	}
	
	int entTrig = CreateEntityByName("trigger_multiple");
	if (IsValidEntity(entTrig))
	{
		char ent_out[32], sName[32];
		Format(ent_out, sizeof ent_out, "OnStartTouch !self,FireUser1,,4,1");
		Format(sName, sizeof sName, "Course%s_Trigger%i", (IsStart ? "Start":"End"), course_num);
		
		DispatchKeyValue(entTrig, "spawnflags", "64");
		SetVariantString(ent_out);
		AcceptEntityInput(entTrig, "AddOutput");
		DispatchKeyValue(entTrig, "targetname", sName);
		DispatchSpawn(entTrig);
		ActivateEntity(entTrig);
		
		int frgEffects = GetEntProp(entTrig, Prop_Send, "m_fEffects");
		frgEffects |= 32;
		SetEntProp(entTrig, Prop_Send, "m_fEffects", frgEffects);
		TeleportEntity(entTrig, course_orig, course_ang, NULL_VECTOR);
		SetEntityModel(entTrig, TRIG_BOX);
		SetEntProp(entTrig, Prop_Send, "m_nSolidType", 2);
		
		float minBounds[3], maxBounds[3];
		minBounds[0] = -80.0; minBounds[1] = -80.0; minBounds[2] = 0.0;
		maxBounds[0] = 80.0; maxBounds[1] = 80.0; maxBounds[2] = 80.0;
		SetEntPropVector(entTrig, Prop_Send, "m_vecMins", minBounds);
		SetEntPropVector(entTrig, Prop_Send, "m_vecMaxs", maxBounds);
		
		if (cDebug.BoolValue)
		{
			DebugLog("Creating trigger model %s Point (%f %f %f) Angle: (%f) for course # %i", (IsStart ? "Start":"End"), 
			course_orig[0], course_orig[1], course_orig[2], course_ang[1], course_num);
		}
	}
}
bool IsUserRoot(int client) { return GetUserAdmin(client).HasFlag(Admin_Root); }
bool IsUserAdmin(int client) { return GetUserAdmin(client).HasFlag(Admin_Generic); }
bool IsValidClient(int client) { return (1 <= client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client)); }
float GetTopTime(int course, int class, int spot) {	return fTimes[course][class][spot-1]; }
char SpeedTime(float time)
{
	int h = (RoundToFloor(time) / 3600) % 24, m = (RoundToFloor(time) / 60) % 60;
	int fs = RoundToFloor(FloatFraction(time) * 1000), is = RoundToFloor(time) % 60; 

	char new_time[MAX_NAME_LENGTH];
	Format(new_time, sizeof new_time, "%ih %im %is %ims", h, m, is, fs);

	return new_time;
}
bool IsApprovedClass(int client)
{
	TFClassType class = TF2_GetPlayerClass(client);
	switch (cAllowedClasses.IntValue)
	{
		case 1:
		{
			if (class == TFClass_Soldier) return true;
		}
		case 2:
		{
			if (class == TFClass_DemoMan) return true;
		}
		case 3:
		{
			if (class == TFClass_Engineer) return true;
		}
		case 4:
		{
			if (class == TFClass_Soldier || class == TFClass_DemoMan || class == TFClass_Engineer) return true;
		}
	}
	return false;
}
/******************************************************
						Events						  *
*******************************************************/
public void OnStartTouch(const char[] output, int caller, int activator, float delay)
{
	int client = activator;
	if (cEnabled.BoolValue && IsValidClient(client) && IsApprovedClass(client))
	{
		char ent_name[32], start_name[32], end_name[32];
		GetEntPropString(caller, Prop_Data, "m_iName", ent_name, sizeof ent_name);
		
		// Not speed running so we let them touch the start trigger.
		if (!bIsSpeedRunning[client] && bCanSpeedRun[client] && bTemp)
		{
			Format(start_name, sizeof start_name, "CourseStart_Trigger%i", GetCourseNumber(ent_name));
			Format(end_name, sizeof end_name, "CourseEnd_Trigger%i", GetCourseNumber(ent_name));
			// Touched a start trigger
			if (strcmp(start_name, ent_name) == 0)
			{
				if (jt) { JT_PrepSpeedRun(client); }
				// Running the course of the trigger they touched.
				iRunningCourse[client] = GetCourseNumber(ent_name);
				bIsSpeedRunning[client] = true;
				fRunnerTimeStart[client] = GetGameTime();
				tSpeedTimer[client] = CreateTimer(1.0, UpdateHud, client, TIMER_REPEAT);
				if (cDebug.BoolValue) { DebugLog("%N has started running course %i", client, iRunningCourse[client]); }
			}
		} else {
			if (bIsSpeedRunning[client])
			{
				Format(start_name, sizeof start_name, "CourseStart_Trigger%i", iRunningCourse[client]);
				if (strcmp(start_name, ent_name) == 0)
				{
					if (jt) { JT_EndSpeedRun(client); }
					iRunningCourse[client] = 0;
					bIsSpeedRunning[client] = false;
					if (tSpeedTimer[client] != INVALID_HANDLE) { delete tSpeedTimer[client]; }
					if (jt) { JT_PrepSpeedRun(client); }
					iRunningCourse[client] = GetCourseNumber(ent_name);
					bIsSpeedRunning[client] = true;
					fRunnerTimeStart[client] = GetGameTime();
					tSpeedTimer[client] = CreateTimer(1.0, UpdateHud, client, TIMER_REPEAT);
					if (cDebug.BoolValue) { DebugLog("%N has re-started the speed timer.", client); }
				}
			}
		}
		if (bIsSpeedRunning[client])
		{
			Format(end_name, sizeof end_name, "CourseEnd_Trigger%i", iRunningCourse[client]);
			if (strcmp(end_name, ent_name) == 0)
			{
				fRunnerTimeEnd[client] = GetGameTime();				
				float chk = GetGameTime() - fRunnerTimeStart[client];
				float finishTime = (fRunnerTimeEnd[client] - fRunnerTimeStart[client]);
				int class = view_as<int>(TF2_GetPlayerClass(client));
				
				char host[64], date[32], name[MAX_NAME_LENGTH];
				GetClientName(client, name, sizeof name);
				cHost.GetString(host, sizeof host);
				FormatTime(date, sizeof date, "%m,%d,%y");
				
				if (GetTopTime(iRunningCourse[client], class, 1) > chk)
				{
					CPrintToChatAll("%s %N has placed #1 on course %i. Time %s [%s]", TAG2, client, iRunningCourse[client], SpeedTime(finishTime), GetPlayerClass(client));
					EmitSoundToAll(RECORD_SOUND_B1, client, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, SNDVOL_NORMAL, SNDPITCH_NORMAL, -1, NULL_VECTOR, NULL_VECTOR, true, 0.0);
					if (cDebug.BoolValue) { DebugLog("%N has beaten record #1 (new time %s)", client, SpeedTime(finishTime)); }
				} else if (GetTopTime(iRunningCourse[client], class, 2) > chk)
				{
					CPrintToChatAll("%s %N has placed #2 on course %i. Time %s [%s]", TAG2, client, iRunningCourse[client], SpeedTime(finishTime), GetPlayerClass(client));
					EmitSoundToAll(RECORD_SOUND_B2, client, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, SNDVOL_NORMAL, SNDPITCH_NORMAL, -1, NULL_VECTOR, NULL_VECTOR, true, 0.0);
					if (cDebug.BoolValue) { DebugLog("%N has beaten record #2 (new time %s)", client, SpeedTime(finishTime)); }
				} else if (GetTopTime(iRunningCourse[client], class, 3) > chk)
				{
					CPrintToChatAll("%s %N has placed #3 on course %i. Time %s [%s]", TAG2, client, iRunningCourse[client], SpeedTime(finishTime), GetPlayerClass(client));
					EmitSoundToAll(RECORD_SOUND_B3, client, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, SNDVOL_NORMAL, SNDPITCH_NORMAL, -1, NULL_VECTOR, NULL_VECTOR, true, 0.0);
					if (cDebug.BoolValue) { DebugLog("%N has beaten record #3 (new time %s)", client, SpeedTime(finishTime)); }
				} else {
					CPrintToChat(client, "%s Good Run! Your time %s [%s]", TAG2, SpeedTime(finishTime), GetPlayerClass(client));
					if (cDebug.BoolValue) { DebugLog("%N has not beaten any record(s). (time %s)", client, SpeedTime(finishTime)); }
				}
				if (jt && !bNoSteamID[client])
				{
					JT_EndSpeedRun(client);
					JT_ReloadPlayerSettings(client);
					AddToQueue(name, sSteamID[client], iRunningCourse[client], finishTime, view_as<int>(class), date, JT_GetSettings(client, 4), host, sMapName);
				} else {
					AddToQueue(name, sSteamID[client], iRunningCourse[client], finishTime, view_as<int>(class), date, 0, host, sMapName);
				}
				iRunningCourse[client] = 0;
				bIsSpeedRunning[client] = false;
				if (tSpeedTimer[client] != INVALID_HANDLE) { delete tSpeedTimer[client]; }
				if (cDebug.BoolValue) { DebugLog("%N has finished a course.", client); }
			}
		}
	}
}
Action eRoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (cEnabled.BoolValue)
	{
		// Load the models
		SpawnModels();
		int client = GetClientOfUserId(event.GetInt("userid"));
		if (bIsSpeedRunning[client])
		{
			if (jt)
			{
				JT_EndSpeedRun(client);
				JT_ReloadPlayerSettings(client);
			}
			iRunningCourse[client] = 0;
			bIsSpeedRunning[client] = false;
			if (tSpeedTimer[client] != INVALID_HANDLE) { delete tSpeedTimer[client]; }
		}
	}
}
Action eEvents(Event event, const char[] name, bool dontBroadcast)
{
	if (cEnabled.BoolValue)
	{
		int client = GetClientOfUserId(event.GetInt("userid"));
		if (bIsSpeedRunning[client])
		{
			if (jt)
			{
				JT_EndSpeedRun(client);
				JT_ReloadPlayerSettings(client);
			}
			iRunningCourse[client] = 0;
			bIsSpeedRunning[client] = false;
			if (tSpeedTimer[client] != INVALID_HANDLE) { delete tSpeedTimer[client]; }
		}
	}
}
/******************************************************
					  ConVar Hooks			    	  *
*******************************************************/
void cEnabledChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (StringToInt(oldValue) != StringToInt(newValue))
		convar.IntValue = StringToInt(newValue);
	if (cDebug.BoolValue) { DebugLog("Changed cEnabled to %s (from %s)", newValue, oldValue); }
}
void cDebugChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (StringToInt(oldValue) != StringToInt(newValue))
		convar.IntValue = StringToInt(newValue);
	if (cDebug.BoolValue) { DebugLog("Changed cDebug to %s (from %s)", newValue, oldValue); }
}
void cAllowedClassesChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (StringToInt(newValue) == 1)
	{
		CPrintToChatAll("%s Only Soldiers can speed run.", TAG2);
		convar.IntValue = StringToInt(newValue);
	} else if (StringToInt(newValue) == 2) {
		CPrintToChatAll("%s Only Demomen can speed run.", TAG2);
		convar.IntValue = StringToInt(newValue);
	} else if (StringToInt(newValue) == 3) {
		CPrintToChatAll("%s Only Engineers can speed run.", TAG2);
		convar.IntValue = StringToInt(newValue);
	}  else if (StringToInt(newValue) == 4) {
		CPrintToChatAll("%s All classes (Soldier, Demoman, Engineers) can speed run.", TAG2);
		convar.IntValue = StringToInt(newValue);
	}
	if (cDebug.BoolValue) { DebugLog("Changed cAllowedClasses to %s (from %s)", newValue, oldValue); }
}
/******************************************************
					DB Functions					  *
******************************************************/
void AddToQueue(char[] name, char[] steamid, int coursenum, float runtime, int class, char[] date, int regen, char[] server, char[] map)
{
	char query[1024];
	Format(query, sizeof query, "INSERT INTO Times VALUES(null, '%s', '%s', '%i', '%f', '%i', '%s', '%i', '%s', '%s');", name, steamid, coursenum, runtime,
								class, date, regen, server, map);
	TimeQue.AddQuery(query);
	QueIndex++;
	if (!bPendingRecords) bPendingRecords = true;
}
void SpawnModels()
{
	char query[100];
	
	dSpeedRank.Format(query, sizeof query, "SELECT * FROM `Courses` WHERE MapName = '%s'", sMapName);
	dSpeedRank.Query(OnSpawnModels, query);
}
void GetPlayerProfile(int client)
{
	char query[100];
	
	dSpeedRank.Format(query, sizeof query, "SELECT * FROM `Players` WHERE SteamID = '%s'", sSteamID[client]);
	dSpeedRank.Query(OnGetPlayerProfile, query, client, DBPrio_High);
}
void SaveTimes()
{
	if (cEnabled.BoolValue)
	{
		if (bPendingRecords)
		{
			if (cDebug.BoolValue) { DebugLog("%i record(s) to save.", QueIndex); }
			dSpeedRank.Execute(TimeQue);
		} else {
			if (cDebug.BoolValue) { DebugLog("No records to save."); }
		}
	}
}
void LoadTimesForMap()
{
	char query[100];
	dSpeedRank.Format(query, sizeof query, "SELECT * FROM TIMES WHERE MapName = '%s' ORDER BY RunTime ASC", sMapName);
	dSpeedRank.Query(OnLoadTimes, query);
	
}
void CheckDatabase()
{
	char dType[32], Ai[32], query[1024];
	// Get the driver type
	DBDriver drivType = dSpeedRank.Driver;
	drivType.GetProduct(dType, sizeof dType);
	// Change this char to change auto increment for the right database.
	strcopy(Ai, sizeof(Ai), (StrEqual(dType, "mysql", false)) ? "AUTO_INCREMENT" : "AUTOINCREMENT");
	
	if (cDebug.BoolValue) { DebugLog("Using DB Driver %s - Set statement to %s", dType, Ai); }
	dSpeedRank.Format(query, sizeof query,
						"CREATE TABLE IF NOT EXISTS `Courses` ( "...
						"`ID` INTEGER PRIMARY KEY %s, "...
						"`CourseNumber` INTEGER NOT NULL, "...
						"`MapName` TEXT NOT NULL, "...
						"`Start1` FLOAT NOT NULL, "...
						"`Start2` FLOAT NOT NULL, "...
						"`Start3` FLOAT NOT NULL, "...
						"`Start4` FLOAT NOT NULL, "...
						"`End1`	FLOAT NOT NULL, "...
						"`End2`	FLOAT NOT NULL, "...
						"`End3`	FLOAT NOT NULL, "...
						"`End4`	FLOAT NOT NULL);", Ai);
	dSpeedRank.Query(OnDefault, query, 0, DBPrio_High);
	dSpeedRank.Format(query, sizeof query, 
						"CREATE TABLE IF NOT EXISTS `Players` ("...
						"`ID` INTEGER PRIMARY KEY %s,"...
						"`SteamID` TEXT NOT NULL UNIQUE,"...
						"`LastSeen`TEXT NOT NULL,"...
						"`UseSounds` INTEGER NOT NULL DEFAULT 1,"...
						"`CanSpeedRun` INTEGER NOT NULL DEFAULT 1);", Ai);
	dSpeedRank.Query(OnDefault, query, 1, DBPrio_High);
	dSpeedRank.Format(query, sizeof query, 
						"CREATE TABLE IF NOT EXISTS `Times` ("...
						"`ID`	INTEGER PRIMARY KEY %s,"...
						"`PlayerName`	TEXT NOT NULL,"...
						"`SteamID`	TEXT NOT NULL,"...
						"`CourseNum`	INTEGER NOT NULL,"...
						"`RunTime`	FLOAT NOT NULL,"...
						"`PlayerClass`	TEXT NOT NULL,"...
						"`CurDate`	TEXT NOT NULL,"...
						"`Regen`	INTEGER NOT NULL,"...
						"`Server`	TEXT NOT NULL,"...
						"`MapName`	TEXT NOT NULL);", Ai);
	dSpeedRank.Query(OnDefault, query, 2, DBPrio_High);
	dSpeedRank.Format(query, sizeof query, 
						"CREATE TABLE IF NOT EXISTS `Cheaters` ("...
						"`ID` INTEGER PRIMARY KEY AUTOINCREMENT,"...
						"`Name`	TEXT NOT NULL,"...
						"`SteamID`	INTEGER NOT NULL,"...
						"`Added`	TEXT NOT NULL,"...
						"`Reason`	TEXT NOT NULL);", Ai);
	dSpeedRank.Query(OnDefault, query, 3, DBPrio_High);
}
/******************************************************
					SQL Callbacks					  *
******************************************************/
public void OnDatabaseConnect(Database db, const char[] error, any data)
{
	if (db == null)
	{
		// SetFailState, because we need this db to function. So disable speed rank for the rest of the map.
		bTemp = true;
		SetFailState("%s", error);
		DebugLog("%s", error);
		return;
	}
	if (cDebug.BoolValue) { DebugLog("Database connected."); }
	dSpeedRank = db;
	
	// We were loaded late, why?
	if (bLate)
	{
		if (bLate) { DebugLog("Loaded normally."); } else { DebugLog("Loaded late."); }
		CPrintToChatAll("%s Plugin {dodgerblue}reloaded{default}.", TAG2);
		iCourseCount = GetCourseCount();
		for (int i = 1; i < MaxClients; i++)
		{
			bIsSpeedRunning[i] = false;
			iRunningCourse[i] = 0;
			bCanSpeedRun[i] = true;
			bHasCourse = true;
			// Since we use steamid for player tracking only do stuff if we can get their id.
			if (IsValidClient(i) && GetClientAuthId(i, AuthId_Steam2, sSteamID[i], sizeof sSteamID))
			{
				GetPlayerProfile(i);
				bNoSteamID[i] = false;
			} else {
				bNoSteamID[i] = true; bCanSpeedRun[i] = false;
			}
		}
	}
	
	CheckDatabase();
}
public void OnDefault(Database db, DBResultSet results, const char[] error, any data)
{
	if (strcmp(error, "") != 0 && cDebug.BoolValue)
	{
		switch (view_as<int>(data))
		{
			// Checked table Courses
			case 0: { DebugLog("SQL query failed at Courses: (%s)", error); }
			case 1: { DebugLog("SQL query failed at Players: (%s)", error); }
			case 2: { DebugLog("SQL query failed at Times: (%s)", error); }
			case 3: { DebugLog("SQL query failed at Cheaters: (%s)", error); }
			case 4: { DebugLog("SQL query failed at Profile Creation: (%s)", error); }
			case 5: { DebugLog("SQL query failed at Profile Update Date: (%s)", error); }
		}
	} else {
		if (cDebug.BoolValue)
		{
			switch (view_as<int>(data))
			{
				// Checked table Courses
				case 0: { DebugLog("Checking Courses, ok!"); }
				case 1: { DebugLog("Checking Players, ok!"); }
				case 2: { DebugLog("Checking Times, ok!"); }
				case 3: { DebugLog("Checking Cheaters, ok!"); }
				case 4: { DebugLog("Created a record for a new speed runner!"); }
				case 5: { DebugLog("Updated a players record with a new date."); }
			}
		}
	}
}
public void OnTimeSaved(Database db, DBResultSet results, const char[] error, any client)
{
	if (db == null || results == null)
	{
		DebugLog("%s", error);
		return;
	}
	if (results.AffectedRows > 0)
	{
		if (cDebug.BoolValue) { DebugLog("Saved %i record to database.", results.AffectedRows); }
	}
}
public void OnDeleteCourse(Database db, DBResultSet results, const char[] error, any client)
{
	if (db == null || results == null)
	{
		DebugLog("%s", error);
		return;
	}
	if (results.AffectedRows > 0)
	{
		CPrintToChat(client, "%s Deleted %i course(s).", TAG2, results.AffectedRows);
		if (cDebug.BoolValue) { DebugLog("Deleted %i course(s)", results.AffectedRows); }
	} else {
		CPrintToChat(client, "%s No courses deleted.", TAG2);
		if (cDebug.BoolValue) { DebugLog("No courses deleted"); }
	}
}
public void OnSpawnModels(Database db, DBResultSet results, const char[] error, any data)
{
	if (db == null || results == null)
	{
		DebugLog("%s", error);
		return;
	}
	if (results.HasResults)
	{
		float orig[3], ang[3], orig2[3], ang2[3];
		while (results.FetchRow())
		{
			orig[0] = results.FetchFloat(3); orig[1] = results.FetchFloat(4); orig[2] = results.FetchFloat(5);
			ang[0] = 0.0; ang[1] = results.FetchFloat(6); ang[2] = 0.0;
			CreateModels(results.FetchInt(1), orig, ang, true);
			if (cDebug.BoolValue) { DebugLog("Course # %i", results.FetchInt(1)); }
			
			orig2[0] = results.FetchFloat(7); orig2[1] = results.FetchFloat(8); orig2[2] = results.FetchFloat(9);
			ang2[0] = 0.0; ang2[1] = results.FetchFloat(10); ang2[2] = 0.0;
			CreateModels(results.FetchInt(1), orig2, ang2, false);
			if (cDebug.BoolValue) { DebugLog("Course # %i", results.FetchInt(1)); }
			iCourseCount++;
			bHasCourse = true;
		}
	} else {
		if (cDebug.BoolValue) { DebugLog("No models to spawn."); }
	}
}
public void OnLoadTimes(Database db, DBResultSet results, const char[] error, any data)
{
	if (db == null || results == null)
	{
		DebugLog("%s", error);
		return;
	}

	if (results.RowCount > 0)
	{
		float start;
		start = GetEngineTime();
		
		if (cDebug.BoolValue) { DebugLog("Parsing Times table (%i records)", results.RowCount); }
		while (results.FetchRow())
		{
			if (iTotalRecords >= MAX_RECORDS-1)
			{
				DebugLog("Cannot load any more records. (%i/%i)", iTotalRecords, results.RowCount);
				return;
			}
			int class, course;
			class = results.FetchInt(5);
			course = results.FetchInt(3);	
			fTimes[course][class][iRecords[course][class]] = results.FetchFloat(4);
			results.FetchString(1, cName[course][class][iRecords[course][class]], sizeof cName[]);
			if (cDebug.BoolValue)
			{
				DebugLog("Record: Name: %s, Course: %i, Time: %f", cName[course][class][iRecords[course][class]], course, fTimes[course][class][iRecords[course][class]]);
			}				
			iRecords[course][class]++; iTotalRecords++;
		}
		float end = (GetEngineTime() - start);
		if (cDebug.BoolValue) { DebugLog("Parsed %i record(s) in %f second(s)", results.RowCount, end); }
	} else {
		if (cDebug.BoolValue) { DebugLog("No times found for %s", sMapName); }	
	}
}
public void OnShowCourse(Database db, DBResultSet results, const char[] error, any client)
{
	if (db == null || results == null)
	{
		DebugLog("%s", error);
		return;
	}

	Panel delMenu = new Panel();
	delMenu.SetTitle("Delete course.");
	if (results.RowCount > 0)
	{
		while (results.FetchRow())
		{
			//int iCourseToDelete = results.FetchInt(1);
			char sCourseName[32];
			Format(sCourseName, sizeof sCourseName, "Course %i", results.FetchInt(1));
			delMenu.DrawItem(sCourseName);
		}
		delMenu.DrawItem("Exit");
		delMenu.Send(client, cAdminDelMenuHandler, MENU_TIME_FOREVER);
	} else {
		CPrintToChat(client, "%s No courses to delete.", TAG2);
	}
}
public void OnGetPlayerProfile(Database db, DBResultSet results, const char[] error, any client)
{
	if (db == null || results == null)
	{
		DebugLog("%s", error);
		return;
	}
	
	if (results.RowCount > 0)
	{
		results.FetchRow();
		bCanSpeedRun[client] = view_as<bool>(results.FetchInt(4));
		
		char query[100], date[32], strcomp[32];
		FormatTime(date, sizeof date, "%m,%d,%y");
		results.FetchString(2, strcomp, sizeof strcomp);
		if (strcmp(strcomp, date) == -1)
		{
			dSpeedRank.Format(query, sizeof query, "UPDATE `Players` SET LastSeen = '%s' WHERE SteamID = '%s';", date, sSteamID[client]);
			dSpeedRank.Query(OnDefault, query, 5);
		}
		
		if (cDebug.BoolValue) { DebugLog("%N connected, and has a record.", client); }
	} else {
		char query[100]; char date[32];
		FormatTime(date, sizeof date, "%m,%d,%y");
		dSpeedRank.Format(query, sizeof query, "INSERT INTO `Players` VALUES(null, '%s', '%s', '1', '1');", sSteamID[client], date);
		dSpeedRank.Query(OnDefault, query, 4);
		if (cDebug.BoolValue) { DebugLog("%N connected, and has no record. Creating.", client); }
	}
}
public void OnSavedCourse(Database db, DBResultSet results, const char[] error, any client)
{
	if (db == null || results == null)
	{
		CPrintToChat(client, "%s The course failed to save. See console.", TAG2);
		PrintToConsole(client, "%s", error);
		return;
	}
	CPrintToChat(client, "%s The course is ready to be run!", TAG2);
	return;
}
/******************************************************
						Timers      		  		  *
******************************************************/
Action LoadMap(Handle timer, any data)
{
	LoadTimesForMap();
}
Action UpdateHud(Handle timer, any client)
{
	int now = RoundFloat(GetGameTime() - fRunnerTimeStart[client]);
	int h = (now / 3600) % 24, m = (now / 60) % 60, s = now % 60;
	bool bEngineer = false;
	if (TF2_GetPlayerClass(client) == TFClass_Engineer) { bEngineer = true; }
	if (bCanUpdate[client])
	{
		SetHudTextParams(0.0, (bEngineer?0.34:0.0), 1.5, 255, 255, 0, 255, 0, 0.0, 0.0, 0.0);
		ShowSyncHudText(client, tYourTime, "Time: %2ih %2im %2is", h, m, s);
	}
	
	float fNow = GetGameTime() - fRunnerTimeStart[client];
	int class = view_as<int>(TF2_GetPlayerClass(client));
	int bLeft, bHour, bMinute, bSecond;
	
	if (GetTopTime(iRunningCourse[client], class, 1) > fNow && bCanUpdate[client])
	{
		// Show how much time they got left to beat the #1 time
		bLeft = RoundFloat(GetTopTime(iRunningCourse[client], class, 1) - fNow);
		bHour = (bLeft / 3600) % 24;
		bMinute = (bLeft / 60) % 60;
		bSecond = bLeft % 60;
		SetHudTextParams(0.0, (bEngineer?0.38:0.05), 1.5, 255, 255, 0, 255, 0, 0.0, 0.0, 0.0);
		ShowSyncHudText(client, tTimeToBeat, "#1 %02i:%02i:%02i", bHour, bMinute, bSecond);
	} else if (GetTopTime(iRunningCourse[client], class, 2) > fNow && bCanUpdate[client])
	{
		// Can we beat the 2nd top time?
		bLeft = RoundFloat(GetTopTime(iRunningCourse[client], class, 2) - fNow);
		bHour = (bLeft / 3600) % 24;
		bMinute = (bLeft / 60) % 60;
		bSecond = bLeft % 60;
		SetHudTextParams(0.0, (bEngineer?0.38:0.05), 1.5, 255, 255, 0, 255, 0, 0.0, 0.0, 0.0);
		ShowSyncHudText(client, tTimeToBeat, "#2 %02i:%02i:%02i", bHour, bMinute, bSecond);
	} else if (GetTopTime(iRunningCourse[client], class, 3) > fNow)
	{
		// Show how much time they got left to beat the #1 time
		bLeft = RoundFloat(GetTopTime(iRunningCourse[client], class, 3) - fNow);
		bHour = (bLeft / 3600) % 24;
		bMinute = (bLeft / 60) % 60;
		bSecond = bLeft % 60;
		if (bCanUpdate[client])
		{
			SetHudTextParams(0.0, (bEngineer?0.38:0.05), 1.5, 255, 255, 0, 255, 0, 0.0, 0.0, 0.0);
			ShowSyncHudText(client, tTimeToBeat, "#3 %02i:%02i:%02i", bHour, bMinute, bSecond);
		}

	}
}
/******************************************************
				Anti speed run cheating     		  *
******************************************************/
// Need to find a way to check for gravity, and speed that doesn't break maps.
public Action OnPlayerRunCmd(int client, int & buttons, int & impulse, float vel[3], float angles[3], int & weapon, int & subtype, int & cmdnum, int & tickcount, int & seed, int mouse[2])
{
	if (cEnabled.BoolValue && bIsSpeedRunning[client])
	{
		iButtons[client] = buttons;
		if (iButtons[client] & IN_SCORE)
		{
			bCanUpdate[client] = false;
		} else {
			bCanUpdate[client] = true;
		}
		if (GetEntityMoveType(client) == MOVETYPE_NOCLIP)
		{
			if (tSpeedTimer[client] != INVALID_HANDLE) { delete tSpeedTimer[client]; }
			bIsSpeedRunning[client] = false;
			iRunningCourse[client] = 0;
			if (jt)
			{
				JT_EndSpeedRun(client);
				JT_ReloadPlayerSettings(client);
			}
			CPrintToChatAll("%s %N NOCLIP detected. Canceling speed run.", TAG2, client);
		}
	}
}
