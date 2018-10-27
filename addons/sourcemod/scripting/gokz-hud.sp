#include <sourcemod>

#include <gokz/core>

#undef REQUIRE_EXTENSIONS
#undef REQUIRE_PLUGIN
#include <updater>



public Plugin myinfo = 
{
	name = "GOKZ HUD", 
	author = "DanZay", 
	description = "GOKZ HUD Module", 
	version = GOKZ_VERSION, 
	url = "https://bitbucket.org/kztimerglobalteam/gokz"
};

#define UPDATE_URL "http://updater.gokz.org/gokz-hud.txt"

#include "gokz-hud/hide_csgo_hud.sp"
#include "gokz-hud/info_panel.sp"
#include "gokz-hud/speed_text.sp"
#include "gokz-hud/timer_text.sp"
#include "gokz-hud/tp_menu.sp"



// =========================  PLUGIN  ========================= //

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_CSGO)
	{
		SetFailState("This plugin is only for CS:GO.");
	}
	RegPluginLibrary("gokz-hud");
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("gokz-hud.phrases");
	
	CreateHooks();
	CreateHudSynchronizers();
}

public void OnAllPluginsLoaded()
{
	if (LibraryExists("updater"))
	{
		Updater_AddPlugin(UPDATE_URL);
	}
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "updater"))
	{
		Updater_AddPlugin(UPDATE_URL);
	}
}



// =========================  CLIENT  ========================= //

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
	OnPlayerRunCmd_TPMenu(client);
	OnPlayerRunCmd_InfoPanel(client, cmdnum);
	OnPlayerRunCmd_SpeedText(client, cmdnum);
	OnPlayerRunCmd_TimerText(client, cmdnum);
}

public void OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast) // player_spawn post hook 
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (IsValidClient(client))
	{
		UpdateCSGOHUD(client);
		UpdateTPMenu(client);
	}
}

public Action OnPlayerDeath(Event event, const char[] name, bool dontBroadcast) // player_death pre hook
{
	event.BroadcastDisabled = true; // Block death notices
}



// =========================  GOKZ  ========================= //

public void GOKZ_OnTimerStart_Post(int client, int course)
{
	OnTimerStart_TimerText(client);
	OnTimerStart_TPMenu(client);
}

public void GOKZ_OnTimerEnd_Post(int client, int course, float time, int teleportsUsed)
{
	OnTimerEnd_TimerText(client);
}

public void GOKZ_OnTimerStopped(int client)
{
	OnTimerStopped_TimerText(client);
}

public void GOKZ_OnPause_Post(int client)
{
	OnPause_TPMenu(client);
}

public void GOKZ_OnResume_Post(int client)
{
	OnResume_TPMenu(client);
}

public void GOKZ_OnMakeCheckpoint_Post(int client)
{
	OnMakeCheckpoint_TPMenu(client);
}

public void GOKZ_OnCountedTeleport_Post(int client)
{
	OnCountedTeleport_TPMenu(client);
}

public void GOKZ_OnOptionChanged(int client, const char[] option, any newValue)
{
	Option coreOption;
	if (!GOKZ_IsCoreOption(option, coreOption))
	{
		return;
	}
	
	OnOptionChanged_TPMenu(client, coreOption);
	OnOptionChanged_SpeedText(client, coreOption);
	OnOptionChanged_TimerText(client, coreOption);
}

public void GOKZ_OnJoinTeam(int client, int team)
{
	OnJoinTeam_TPMenu(client);
}

public void GOKZ_OnCustomStartPositionSet_Post(int client, const float position[3], const float angles[3])
{
	OnCustomStartPositionSet_TPMenu(client);
}

public void GOKZ_OnCustomStartPositionCleared_Post(int client)
{
	OnCustomStartPositionCleared_TPMenu(client);
}



// =========================  PRIVATE  ========================= //

static void CreateHooks()
{
	HookEvent("player_spawn", OnPlayerSpawn, EventHookMode_Post);
	HookEvent("player_death", OnPlayerDeath, EventHookMode_Pre);
}

static void CreateHudSynchronizers()
{
	CreateHudSynchronizerSpeedText();
	CreateHudSynchronizerTimerText();
} 