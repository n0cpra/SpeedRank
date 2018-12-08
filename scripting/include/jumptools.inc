/** Double-include prevention */
#if defined _jumpassist_included_
  #endinput
#endif
#define _jumptools_included_

public SharedPlugin __pl_jumptools = 
{
	name = "jumptools",
	file = "jumptools.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

public void __pl_jumptools_SetNTVOptional()
{
	MarkNativeAsOptional("JT_GetSettings");
	MarkNativeAsOptional("JT_PrepSpeedRun");
	MarkNativeAsOptional("JT_EndSpeedRun");
	MarkNativeAsOptional("JT_GotoClient");
	MarkNativeAsOptional("JT_ReloadPlayerSettings");
}
/*
	@param			client id
	@param			target id
	@noreturn
	
	Teleports the client to target.
*/
native void JT_GotoClient(int client, int target);
/*
	@param			client
	@param			-1 for map class and the rest 0-4
	@return			true if setting is on, false if off.
		
	@note Settings to get 0 Gets the status of superman, 1 Health Regen, 2 Ammo Regen, 3 Preview
*/
native bool JT_GetSettings(int client, int JTSetting);

/*
	@param			client
	@return 		true if success, false if failure.
	
	Preps the user for a speed run. Disables regen, saving, teleporting, and preview.
*/
native bool JT_PrepSpeedRun(int client);
/*
	@param			client
	@noreturn
	
	Allows the client to use jumptools features again.
*/
native void JT_EndSpeedRun(int client);

/*
	@param			client
	@return 		true if success, false if failure.
	
	Reload the players stored settings.
*/
native bool JT_ReloadPlayerSettings(int client);
native bool IsSpeedRunning(int client);
// forward void OnProfileLoaded(int client, int red, int green, int blue);
// forward void OnSavedLocation(int client, float fOrigin, float fAngles, float fVelocity);
// forward void OnTeleportToSave(int client);