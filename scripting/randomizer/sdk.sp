static Handle g_hSDKEquipWearable;
static Handle g_hSDKDoClassSpecialSkill;
static Handle g_hSDKGetBaseEntity;

static Handle g_hDHookSecondaryAttack;
static Handle g_hDHookGiveNamedItem;

static int g_iOffsetItemDefinitionIndex = -1;
static Address g_pPlayerSharedOuter;

static int g_iHookIdGiveNamedItem[TF_MAXPLAYERS+1];
static bool g_bDoClassSpecialSkill[TF_MAXPLAYERS+1];

public void SDK_Init()
{
	GameData hGameData = new GameData("randomizer");
	if (!hGameData)
		SetFailState("Could not find randomizer gamedata");
	
	DHook_CreateDetour(hGameData, "CTFPlayer::GetMaxAmmo", DHook_GetMaxAmmoPre, _);
	DHook_CreateDetour(hGameData, "CTFPlayer::Taunt", DHook_TauntPre, DHook_TauntPost);
	DHook_CreateDetour(hGameData, "CTFPlayer::CanAirDash", _, DHook_CanAirDashPost);
	DHook_CreateDetour(hGameData, "CTFPlayer::ValidateWeapons", DHook_ValidateWeaponsPre, _);
	DHook_CreateDetour(hGameData, "CTFPlayer::OnDealtDamage", DHook_OnDealtDamagePre, DHook_OnDealtDamagePost);
	DHook_CreateDetour(hGameData, "CTFPlayer::DoClassSpecialSkill", DHook_DoClassSpecialSkillPre, DHook_DoClassSpecialSkillPost);
	DHook_CreateDetour(hGameData, "CTFPlayerShared::UpdateItemChargeMeters", DHook_UpdateItemChargeMetersPre, DHook_UpdateItemChargeMetersPost);
	DHook_CreateDetour(hGameData, "CTFPlayerShared::UpdateChargeMeter", DHook_UpdateChargeMeterPre, DHook_UpdateChargeMeterPost);
	
	g_hDHookSecondaryAttack = DHook_CreateVirtual(hGameData, "CBaseCombatWeapon::SecondaryAttack");
	g_hDHookGiveNamedItem = DHook_CreateVirtual(hGameData, "CTFPlayer::GiveNamedItem");
	
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, "CBaseEntity::GetBaseEntity");
	PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);
	g_hSDKGetBaseEntity = EndPrepSDKCall();
	if (!g_hSDKGetBaseEntity)
		LogError("Failed to create call: CBaseEntity::GetBaseEntity");
	
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, "CBasePlayer::EquipWearable");
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	g_hSDKEquipWearable = EndPrepSDKCall();
	if (!g_hSDKEquipWearable)
		LogError("Failed to create call: CBasePlayer::EquipWearable");
	
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "CTFPlayer::DoClassSpecialSkill");
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	g_hSDKDoClassSpecialSkill = EndPrepSDKCall();
	if (!g_hSDKDoClassSpecialSkill)
		LogError("Failed to create call: CTFPlayer::DoClassSpecialSkill");
	
	g_pPlayerSharedOuter = view_as<Address>(hGameData.GetOffset("CTFPlayerShared::m_pOuter"));
	g_iOffsetItemDefinitionIndex = hGameData.GetOffset("CEconItemView::m_iItemDefinitionIndex");
	
	delete hGameData;
}

static void DHook_CreateDetour(GameData hGameData, const char[] sName, DHookCallback preCallback = INVALID_FUNCTION, DHookCallback postCallback = INVALID_FUNCTION)
{
	Handle hDetour = DHookCreateFromConf(hGameData, sName);
	if (!hDetour)
	{
		LogError("Failed to create detour: %s", sName);
	}
	else
	{
		if (preCallback != INVALID_FUNCTION)
			if (!DHookEnableDetour(hDetour, false, preCallback))
				LogError("Failed to enable pre detour: %s", sName);
		
		if (postCallback != INVALID_FUNCTION)
			if (!DHookEnableDetour(hDetour, true, postCallback))
				LogError("Failed to enable post detour: %s", sName);
		
		delete hDetour;
	}
}

static Handle DHook_CreateVirtual(GameData hGameData, const char[] sName)
{
	Handle hHook = DHookCreateFromConf(hGameData, sName);
	if (!hHook)
		LogError("Failed to create hook: %s", sName);
	
	return hHook;
}

void SDK_HookGiveNamedItem(int iClient)
{
	if (g_hDHookGiveNamedItem && !g_bTF2Items)
		g_iHookIdGiveNamedItem[iClient] = DHookEntity(g_hDHookGiveNamedItem, false, iClient, DHook_GiveNamedItemRemoved, DHook_GiveNamedItemPre);
}

void SDK_UnhookGiveNamedItem(int iClient)
{
	if (g_iHookIdGiveNamedItem[iClient])
	{
		DHookRemoveHookID(g_iHookIdGiveNamedItem[iClient]);
		g_iHookIdGiveNamedItem[iClient] = 0;	
	}
}

bool SDK_IsGiveNamedItemActive()
{
	for (int iClient = 1; iClient <= MaxClients; iClient++)
		if (g_iHookIdGiveNamedItem[iClient])
			return true;
	
	return false;
}

void SDK_HookWeapon(int iWeapon)
{
	DHookEntity(g_hDHookSecondaryAttack, true, iWeapon, _, DHook_SecondaryWeaponPost);
	
	SDKHook(iWeapon, SDKHook_Reload, Hook_ReloadPre);
}

void SDK_EquipWearable(int iClient, int iWearable)
{
	if (g_hSDKEquipWearable)
		SDKCall(g_hSDKEquipWearable, iClient, iWearable);
}

bool SDK_DoClassSpecialSkill(int iClient)
{
	if (g_hSDKDoClassSpecialSkill)
		return SDKCall(g_hSDKDoClassSpecialSkill, iClient);
	
	return false;
}

public MRESReturn DHook_GetMaxAmmoPre(int iClient, Handle hReturn, Handle hParams)
{
	int iAmmoType = DHookGetParam(hParams, 1);
	TFClassType nClass = DHookGetParam(hParams, 2);
	
	if (nClass != view_as<TFClassType>(-1))
		return MRES_Ignored;
	
	if (iAmmoType == TF_AMMO_METAL)
	{
		//Metal works differently, engineer have max metal 200 while others have 100
		DHookSetParam(hParams, 2, TFClass_Engineer);
		return MRES_ChangedHandled;
	}
	
	//By default iClassNumber returns -1, which would get client's class instead of given iClassNumber.
	//However using client's class can cause max ammo calculate to be incorrect,
	//We want to set iClassNumber to whatever class would normaly use weapon from iAmmoIndex.
	//TODO check shortstop's max ammo
	int iWeapon = TF2_GetItemFromAmmoType(iClient, iAmmoType);
	if (iWeapon <= MaxClients)
		return MRES_Ignored;
	
	TFClassType nDefaultClass = TF2_GetDefaultClassFromItem(iClient, iWeapon);
	DHookSetParam(hParams, 2, nDefaultClass);
	return MRES_ChangedHandled;
}

public MRESReturn DHook_TauntPre(int iClient, Handle hParams)
{
	//Player wants to taunt, set class to whoever can actually taunt with active weapon
	
	int iWeapon = GetEntPropEnt(iClient, Prop_Send, "m_hActiveWeapon");
	if (iWeapon <= MaxClients)
		return;
	
	TFClassType nClass = TF2_GetDefaultClassFromItem(iClient, iWeapon);
	if (nClass != TFClass_Unknown)
		TF2_SetPlayerClass(iClient, nClass);
}

public MRESReturn DHook_TauntPost(int iClient, Handle hParams)
{
	//Set class back to what it was
	TF2_SetPlayerClass(iClient, g_iClientClass[iClient]);
}

public MRESReturn DHook_CanAirDashPost(int iClient, Handle hReturn)
{
	//Atomizer's extra jumps does not work for non-scouts, fix that
	if (!DHookGetReturn(hReturn))
	{
		int iWeapon = GetEntPropEnt(iClient, Prop_Send, "m_hActiveWeapon");
		
		float flVal;
		if (!TF2_WeaponFindAttribute(iWeapon, ATTRIB_AIR_DASH_COUNT, flVal))
			return MRES_Ignored;
		
		int iAirDash = GetEntProp(iClient, Prop_Send, "m_iAirDash");
		if (iAirDash < RoundToNearest(flVal))
		{
			SetEntProp(iClient, Prop_Send, "m_iAirDash", iAirDash + 1);
			DHookSetReturn(hReturn, true);
			return MRES_Supercede;
		}
	}
	
	return MRES_Ignored;
}

public MRESReturn DHook_ValidateWeaponsPre(int iClient, Handle hParams)
{
	//Dont validate any weapons, TF2 attempting to remove randomizer weapon for player's TF2 loadout
	return MRES_Supercede;
}

public MRESReturn DHook_OnDealtDamagePre(int iClient, Handle hParams)
{
	//Gas Passer meter have hardcode pyro check in this call
	TF2_SetPlayerClass(iClient, TFClass_Pyro);
}

public MRESReturn DHook_OnDealtDamagePost(int iClient, Handle hParams)
{
	TF2_SetPlayerClass(iClient, g_iClientClass[iClient]);
}

public MRESReturn DHook_DoClassSpecialSkillPre(int iClient, Handle hReturn)
{
	//There 3 things going on in this function depending on player class attempting to:
	//If Demoman, detonate stickies or charge
	//If Engineer, pickup buildings
	//If Spy, cloak or uncloak
	//
	//We want to prevent Engineer and Spy stuffs from reload,
	//and allow demoman stuffs only if holding reload, not from attack2
	
	g_bDoClassSpecialSkill[iClient] = true;
	int iActiveWeapon = GetEntPropEnt(iClient, Prop_Send, "m_hActiveWeapon");
	if (iActiveWeapon <= MaxClients)
		return MRES_Ignored;
	
	int iButtons = GetClientButtons(iClient);
	if (iButtons & IN_ATTACK2)
	{
		//Check if active weapon does something with attack2 and not replaced to reload, if so prevent call
		if (iActiveWeapon > MaxClients && Controls_IsUsingAttack2(iActiveWeapon) && !Controls_IsPassive(iActiveWeapon))
		{
			DHookSetReturn(hReturn, false);
			return MRES_Supercede;
		}
	}
	
	for (int iSlot = 0; iSlot <= WeaponSlot_BuilderEngie; iSlot++)
	{
		int iWeapon = TF2_GetItemInSlot(iClient, iSlot);
		if (iWeapon > MaxClients && Controls_IsPassive(iWeapon))
		{
			//This weapon is passive, determine whenever if attack2 or reload should be used, and change class for passive weapon
			
			if (iButtons & IN_RELOAD && iWeapon != iActiveWeapon && Controls_IsUsingAttack2(iActiveWeapon))
			{
				TF2_SetPlayerClass(iClient, TF2_GetDefaultClassFromItem(iClient, iWeapon));
				return MRES_Ignored;
			}
			else if (iButtons & IN_ATTACK2)
			{
				TF2_SetPlayerClass(iClient, TF2_GetDefaultClassFromItem(iClient, iWeapon));
				return MRES_Ignored;
			}
		}
	}
		
	if (iButtons & IN_RELOAD && !(iButtons & IN_ATTACK2))
	{
		//Nothing fancy need to do from SDK_DoClassSpecialSkill reload, prevent call
		DHookSetReturn(hReturn, false);
		return MRES_Supercede;
	}
	
	return MRES_Ignored;
}

public MRESReturn DHook_DoClassSpecialSkillPost(int iClient, Handle hReturn)
{
	TF2_SetPlayerClass(iClient, g_iClientClass[iClient]);
}

public MRESReturn DHook_UpdateItemChargeMetersPre(Address pPlayerShared)
{
	//Dragon Fury and Gas Passer meter have hardcode pyro check in this call
	int iClient = GetClientFromPlayerShared(pPlayerShared);
	TF2_SetPlayerClass(iClient, TFClass_Pyro);
}

public MRESReturn DHook_UpdateItemChargeMetersPost(Address pPlayerShared)
{
	int iClient = GetClientFromPlayerShared(pPlayerShared);
	TF2_SetPlayerClass(iClient, g_iClientClass[iClient]);
}

public MRESReturn DHook_UpdateChargeMeterPre(Address pPlayerShared)
{
	//This function is only used to manage demoshield meter, but have hardcode demoman class
	int iClient = GetClientFromPlayerShared(pPlayerShared);
	TF2_SetPlayerClass(iClient, TFClass_DemoMan);
}

public MRESReturn DHook_UpdateChargeMeterPost(Address pPlayerShared)
{
	int iClient = GetClientFromPlayerShared(pPlayerShared);
	TF2_SetPlayerClass(iClient, g_iClientClass[iClient]);
}

public MRESReturn DHook_SecondaryWeaponPost(int iWeapon)
{
	//Why is this function getting called from tf_viewmodel angery
	char sClassname[256];
	GetEntityClassname(iWeapon, sClassname, sizeof(sClassname));
	if (StrContains(sClassname, "tf_weapon_") != 0)
		return;
	
	int iClient = GetEntPropEnt(iWeapon, Prop_Send, "m_hOwnerEntity");
	
	//If DoClassSpecialSkill not called during secondary attack, do it anyway lol
	if (!g_bDoClassSpecialSkill[iClient])
	{
		g_bDoClassSpecialSkill[iClient] = true;
		SDK_DoClassSpecialSkill(iClient);
	}
	
	g_bDoClassSpecialSkill[iClient] = false;
}

public MRESReturn DHook_GiveNamedItemPre(int iClient, Handle hReturn, Handle hParams)
{
	if (DHookIsNullParam(hParams, 1) || DHookIsNullParam(hParams, 3))
	{
		DHookSetReturn(hReturn, 0);
		return MRES_Override;
	}
	
	char sClassname[256];
	DHookGetParamString(hParams, 1, sClassname, sizeof(sClassname));
	int iIndex = DHookGetParamObjectPtrVar(hParams, 3, g_iOffsetItemDefinitionIndex, ObjectValueType_Int) & 0xFFFF;
	
	Action action = GiveNamedItem(iClient, sClassname, iIndex);
	if (action >= Plugin_Handled)
	{
		DHookSetReturn(hReturn, 0);
		return MRES_Override;
	}
	
	return MRES_Ignored;
}

public void DHook_GiveNamedItemRemoved(int iHookId)
{
	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (g_iHookIdGiveNamedItem[iClient] == iHookId)
		{
			g_iHookIdGiveNamedItem[iClient] = 0;
			return;
		}
	}
}

public Action Hook_ReloadPre(int iWeapon)
{
	//Weapon unable to be reloaded from cloak, but coded in revolver only, and only for Spy class
	int iClient = GetEntPropEnt(iWeapon, Prop_Send, "m_hOwnerEntity");
	if (TF2_IsPlayerInCondition(iClient, TFCond_Cloaked))
		return Plugin_Handled;
	
	return Plugin_Continue;
}

static int GetClientFromPlayerShared(Address pPlayerShared)
{
	Address pEntity = view_as<Address>(LoadFromAddress(pPlayerShared + g_pPlayerSharedOuter, NumberType_Int32));
	return SDKCall(g_hSDKGetBaseEntity, pEntity);
}