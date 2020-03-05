/*
	Tracking of jump type, speed, strafes and more.
*/



// =====[ STRUCTS ]============================================================

enum struct Pose
{
	float position[3];
	float orientation[3];
	float velocity[3];
	float speed;
	int durationTicks;
	int overlap;
	int deadair;
	int syncTicks;
}



// =====[ GLOBAL VARIABLES ]===================================================

static int entityTouchCount[MAXPLAYERS + 1];
static bool validCmd[MAXPLAYERS + 1]; // Whether no illegal action is detected	
static const float playerMins[3] =  { -16.0, -16.0, 0.0 };
static const float playerMaxs[3] =  { 16.0, 16.0, 0.0 };
static bool beginJumpstat[MAXPLAYERS + 1];
static bool doFailstatAlways[MAXPLAYERS + 1];
static bool isInAir[MAXPLAYERS + 1];
static const Jump emptyJump;



// =====[ DEFINITIONS ]========================================================

// We cannot return enum structs and it's annoying
// The modulo operator is broken, so we can't access this using negative numbers
// (https://github.com/alliedmodders/sourcepawn/issues/456). We use the method
// described here instead: https://stackoverflow.com/a/42131603/7421666
#define pose(%1) (poseHistory[this.jumper][((this.poseIndex + (%1)) % JS_FAILSTATS_MAX_TRACKED_TICKS + JS_FAILSTATS_MAX_TRACKED_TICKS) % JS_FAILSTATS_MAX_TRACKED_TICKS])



// =====[ TRACKING ]===========================================================

// We cannot put that into the tracker struct
Pose poseHistory[MAXPLAYERS + 1][JS_FAILSTATS_MAX_TRACKED_TICKS];

enum struct JumpTracker
{
	Jump jump;
	int jumper;
	int jumpoffTick;
	int poseIndex;
	int strafeDirection;
	int lastJumpTick;
	int lastType;
	int lastWPressedTick;
	int syncTicks;
	int crouchReleaseTick;
	bool failstatBlockDetected;
	bool failstatFailed;
	bool failstatValid;
	float failstatBlockHeight;
	float takeoffOrigin[3];
	float takeoffVelocity[3];
	float position[3];
	
	void Init(int jumper)
	{
		this.jumper = jumper;
		this.jump.jumper = jumper;
	}
	
	
	
	// =====[ ENTRYPOINTS ]=======================================================
	
	void Reset(bool jumped, bool ladderJump, bool jumpbug)
	{
		// We need to do that before we reset the jump cause we need the
		// offset and type of the previous jump
		this.lastType = this.DetermineType(jumped, ladderJump, jumpbug);
		
		// We need this for weirdjump w-release
		int releaseWTemp = this.jump.releaseW;
	
		// Reset all stats
		this.jump = emptyJump;
		this.jump.type = this.lastType;
		this.jump.jumper = this.jumper;
		this.syncTicks = 0;
		this.strafeDirection = StrafeDirection_None;
		this.jump.releaseW = 100;
		this.crouchReleaseTick = 0;
		
		// Handle weirdjump w-release
		if (this.jump.type == JumpType_WeirdJump)
		{
			this.jump.releaseW = releaseWTemp;
		}
		
		// You have to release crouch 3 ticks before landing
		this.jump.crouchRelease = this.crouchReleaseTick - Movement_GetLandingTick(this.jumper) - 3;
		
		// Reset pose history
		this.poseIndex = 0;
	}
	
	void Begin()
	{
		// Initialize stats
		this.CalcTakeoff();
		this.AdjustLowpreJumptypes();
		
		this.failstatBlockDetected = this.jump.type != JumpType_LadderJump;
		this.failstatFailed = false;
		this.failstatValid = false;
		this.failstatBlockHeight = this.takeoffOrigin[2];
		
		// Store the original type for the always stats
		this.jump.originalType = this.jump.type;
		
		// Notify everyone about the takeoff
		Call_OnTakeoff(this.jumper, this.jump.type);
		
		// Measure first tick of jumpstat
		this.Update();
	}
	
	void Update()
	{
		this.UpdatePoseHistory();
		
		float speed = pose(0).speed;
		
		this.jump.height = FloatMax(this.jump.height, this.position[2] - this.takeoffOrigin[2]);
		this.jump.maxSpeed = FloatMax(this.jump.maxSpeed, speed);
		this.jump.crouchTicks += Movement_GetDucking(this.jumper) ? 1 : 0;
		this.syncTicks += speed > pose(-1).speed ? 1 : 0;
		this.jump.durationTicks++;
		
		this.UpdateCrouchRelease();
		this.UpdateStrafes();
		this.UpdateFailstat();
		this.UpdatePoseStats();
		
		this.lastType = this.jump.type;
	}
	
	void End()
	{
		// The jump is so invalid we don't even have to bother
		if (this.jump.type == JumpType_FullInvalid)
		{
			return;
		}
	
		// Measure last tick of jumpstat
		this.Update();
		
		// Try to prevent a form of booster abuse
		if (this.jump.type != JumpType_LadderJump &&
			this.jump.type != JumpType_WeirdJump &&
			this.jump.durationTicks > 100)
		{
			this.Invalidate();
		}
		
		// Fix the edgebug for the current position
		Movement_GetNobugLandingOrigin(this.jumper, this.position);
		
		// Calculate the last stats
		this.jump.distance = this.CalcDistance();
		this.jump.sync = float(this.syncTicks) / float(this.jump.durationTicks) * 100.0;
		this.jump.offset = this.position[2] - this.takeoffOrigin[2];
		this.jump.duration = this.jump.durationTicks * GetTickInterval();
		
		this.EndBlockDistance();
		
		// Make sure the ladder has no offset for ladder jumps
		if (this.jump.type == JumpType_LadderJump)
		{
			this.TraceLadderOffset(this.position[2]);
		}
		
		// Calculate always-only stats
		if (GOKZ_JS_GetOption(this.jumper, JSOption_JumpstatsAlways) == JSToggleOption_Enabled)
		{
			this.EndAlwaysJumpstats();
		}
		
		// Call the appropriate functions for either regular or always stats
		this.Callback();
	}
	
	void Invalidate()
	{
		if (this.jump.type != JumpType_Invalid &&
			this.jump.type != JumpType_FullInvalid)
		{
			this.jump.type = JumpType_Invalid;
			Call_OnJumpInvalidated(this.jumper);
		}
	}
	
	
	
	// =====[ BEGIN HELPERS ]=====================================================
	
	void CalcTakeoff()
	{
		if (this.jump.type == JumpType_Jumpbug)
		{
			// The player never really touches the gound, so we have to
			// construct a takeoff origin
			float height = this.takeoffOrigin[2];
			Movement_GetOrigin(this.jumper, this.takeoffOrigin);
			this.takeoffOrigin[2] = height; 
		}
		else
		{
			Movement_GetTakeoffOrigin(this.jumper, this.takeoffOrigin);
		}
		
		// Correct the takeoff speed and velocity
		this.jump.preSpeed = GOKZ_GetTakeoffSpeed(this.jumper);
		poseHistory[this.jumper][0].speed = this.jump.preSpeed;
		Movement_GetVelocity(this.jumper, this.takeoffVelocity);
	}
	
	void AdjustLowpreJumptypes()
	{
		// Exclude SKZ and VNL stats.
		if (this.jump.preSpeed > 290.0)
		{
			if (this.jump.type == JumpType_Bhop &&
				this.jump.preSpeed < 360.0)
			{
				this.jump.type = JumpType_LowpreBhop;
			}
			else if (this.jump.type == JumpType_WeirdJump &&
					 this.jump.preSpeed < 300.0)
			{
				this.jump.type = JumpType_LowpreWeirdJump;
			}
		}
	}
	
	int DetermineType(bool jumped, bool ladderJump, bool jumpbug)
	{
		if (entityTouchCount[this.jumper] > 0)
		{
			return JumpType_Invalid;
		}
		else if (ladderJump)
		{
			if (GetGameTickCount() - this.lastJumpTick <= JS_MAX_BHOP_GROUND_TICKS)
			{
				return JumpType_Ladderhop;
			}
			else
			{
				return JumpType_LadderJump;
			}
		}
		else if (!jumped)
		{
			return JumpType_Fall;
		}
		else if (jumpbug)
		{
			// Check for no offset
			if (this.takeoffOrigin[2] <= this.position[2] &&
				this.lastType == JumpType_LongJump)
			{
				return JumpType_Jumpbug;
			}
		}
		else if (this.HitBhop())
		{
			// Check for no offset
			if (FloatAbs(this.jump.offset) < EPSILON)
			{
				switch (this.lastType)
				{
					case JumpType_LongJump:return JumpType_Bhop;
					case JumpType_Bhop:return JumpType_MultiBhop;
					case JumpType_LowpreBhop:return JumpType_MultiBhop;
					case JumpType_MultiBhop:return JumpType_MultiBhop;
					default:return JumpType_Other;
				}
			}
			// Check for weird jump
			else if (this.lastType == JumpType_Fall &&
					 this.ValidWeirdJumpDropDistance())
			{
				return JumpType_WeirdJump;
			}
			else
			{
				return JumpType_Other;
			}
		}
		return JumpType_LongJump;
	}
	
	bool HitBhop()
	{
		return Movement_GetTakeoffCmdNum(this.jumper) - Movement_GetLandingCmdNum(this.jumper) <= JS_MAX_BHOP_GROUND_TICKS;
	}
	
	bool ValidWeirdJumpDropDistance()
	{
		if (this.jump.offset < -1 * JS_MAX_WEIRDJUMP_FALL_OFFSET)
		{
			// Don't bother telling them if they fell a very far distance
			if (!GetJumpstatsDisabled(this.jumper) && this.jump.offset >= -2 * JS_MAX_WEIRDJUMP_FALL_OFFSET)
			{
				GOKZ_PrintToChat(this.jumper, true, "%t", "Dropped Too Far (Weird Jump)", -1 * this.jump.offset, JS_MAX_WEIRDJUMP_FALL_OFFSET);
			}
			return false;
		}
		return true;
	}
	
	
	
	// =====[ UPDATE HELPERS ]====================================================
	
	// We split that up in two functions to get a reference to the pose so we
	// don't have to recalculate the pose index all the time.
	void UpdatePoseHistory()
	{
		this.poseIndex++;
		this.UpdatePose(pose(0));
	}
	
	void UpdatePose(Pose p)
	{
		Movement_GetOrigin(this.jumper, p.position);
		Movement_GetVelocity(this.jumper, p.velocity);
		Movement_GetEyeAngles(this.jumper, p.orientation);
		p.speed = GetVectorHorizontalLength(p.velocity);
		
		// We use the current position in a lot of places, so we store it
		// separately to avoid calling 'pose' all the time.
		CopyVector(p.position, this.position);
	}
	
	// We split that up in two functions to get a reference to the pose so we
	// don't have to recalculate the pose index all the time. We seperate that
	// from UpdatePose() cause those stats are not calculated yet when we call that.
	void UpdatePoseStats()
	{
		this.UpdatePoseStats_P(pose(0));
	}
	
	void UpdatePoseStats_P(Pose p)
	{
		p.durationTicks = this.jump.durationTicks;
		p.syncTicks = this.syncTicks;
		p.overlap = this.jump.overlap;
		p.deadair = this.jump.deadair;
	}
	
	void UpdateOnGround()
	{
		// Using Movement_GetTakeoffTick or doing it only in Begin() is unreliable
		// for some reason.
		this.jumpoffTick = GetGameTickCount();
		
		// We want acurate values to measure the first tick
		this.UpdatePose(poseHistory[this.jumper][0]);
	}
	
	void UpdateWRelease()
	{
		// We also check IN_BACK cause that happens for backwards ladderjumps
		if (Movement_GetButtons(this.jumper) & IN_FORWARD ||
			Movement_GetButtons(this.jumper) & IN_BACK)
		{
			this.lastWPressedTick = GetGameTickCount();
		}
		else if (this.jump.releaseW > 99)
		{
			this.jump.releaseW = this.lastWPressedTick - this.jumpoffTick;
		}
	}
	
	void UpdateCrouchRelease()
	{
		if (Movement_GetButtons(this.jumper) & IN_DUCK)
		{
			this.crouchReleaseTick = 0;
		}
		else if (this.crouchReleaseTick == 0)
		{
			this.crouchReleaseTick = GetGameTickCount();
		}
	}
	
	void UpdateStrafes()
	{
		// Strafe direction
		if (Movement_GetTurningLeft(this.jumper) &&
			this.strafeDirection != StrafeDirection_Left)
		{
			this.strafeDirection = StrafeDirection_Left;
			this.jump.strafes++;
		}
		else if (Movement_GetTurningRight(this.jumper) &&
				 this.strafeDirection != StrafeDirection_Right)
		{
			this.strafeDirection = StrafeDirection_Right;
			this.jump.strafes++;
		}
		
		// Overlap / Deadair
		int buttons = Movement_GetButtons(this.jumper);
		int overlap = buttons & IN_MOVERIGHT && buttons & IN_MOVELEFT ? 1 : 0;
		int deadair = !(buttons & IN_MOVERIGHT) && !(buttons & IN_MOVELEFT) ? 1 : 0;
		
		// Sync / Gain / Loss
		float deltaSpeed = pose(0).speed - pose(-1).speed;
		bool gained = deltaSpeed > EPSILON;
		bool lost = deltaSpeed < -EPSILON;
		
		// Width
		float width = FloatAbs(CalcDeltaAngle(pose(0).orientation[1], pose(-1).orientation[1]));
		
		// Overall stats
		this.jump.overlap += overlap;
		this.jump.deadair += deadair;
		this.jump.width += width;
		
		// Individual stats
		if (this.jump.strafes >= JS_MAX_TRACKED_STRAFES)
		{
			return;
		}
		
		int i = this.jump.strafes;
		this.jump.strafes_ticks[i]++;
		
		this.jump.strafes_overlap[i] += overlap;
		this.jump.strafes_deadair[i] += deadair;
		this.jump.strafes_loss[i] += lost ? -1 * deltaSpeed : 0.0;
		this.jump.strafes_width[i] += width;
		
		if (gained)
		{
			this.jump.strafes_gainTicks[i]++;
			this.jump.strafes_gain[i] += deltaSpeed;
		}
	}
	
	void UpdateFailstat()
	{
		int coordDist, distSign;
		float failstatPosition[3], block[3], traceStart[3];
		
		// There's no point in going further if we're already done
		if (this.failstatValid || this.failstatFailed)
		{
			return;
		}
		
		// Get the coordinate system orientation.
		GetCoordOrientation(this.position, this.takeoffOrigin, coordDist, distSign);
		
		// For ladderjumps we have to find the landing block early so we know at which point the jump failed.
		// For this, we search for the block 10 units above the takeoff origin, assuming the player already
		// traveled a significant enough distance in the direction of the block at this time.
		if (!this.failstatBlockDetected && 
			this.position[2] - this.takeoffOrigin[2] < 10.0 && 
			this.jump.height > 10.0)
		{
			this.failstatBlockDetected = true;
			
			// Setup a trace to search for the block
			CopyVector(this.takeoffOrigin, traceStart);
			traceStart[2] -= 5.0;
			CopyVector(traceStart, block);
			traceStart[coordDist] += JS_MIN_LAJ_BLOCK_DISTANCE * distSign;
			block[coordDist] += JS_MAX_LAJ_FAILSTAT_DISTANCE * distSign;
			
			// Search for the block
			if (!TraceHullPosition(traceStart, block, playerMins, playerMaxs, block))
			{
				// Mark the calculation as failed
				this.failstatFailed = true;
				return;
			}
			
			// Find the block height
			block[2] += 5.0;
			this.failstatBlockHeight = this.FindBlockHeight(block, float(distSign) * 17.0, coordDist, 10.0) - 0.031250;
		}
		
		// Only do the calculation once we're below the block level
		if (this.position[2] >= this.failstatBlockHeight)
		{
			// We need that cause we can duck after getting lower than the failstat
			// height and still make the block.
			this.failstatValid = false;
			return;
		}
		
		// Calculate the true origin where the player would have hit the ground.
		this.GetFailOrigin(this.failstatBlockHeight, failstatPosition, -1);
		
		// Calculate the jump distance.
		this.jump.distance = FloatAbs(GetVectorHorizontalDistance(failstatPosition, this.takeoffOrigin));
		
		// Construct the maximum landing origin, assuming the player reached
		// at least the middle of the gap.
		CopyVector(this.takeoffOrigin, block);
		block[coordDist] = 2 * failstatPosition[coordDist] - this.takeoffOrigin[coordDist];
		block[!coordDist] = failstatPosition[!coordDist]; 
		block[2] = this.failstatBlockHeight;
		
		// Calculate block stats
		if ((this.lastType == JumpType_LongJump || 
				this.lastType == JumpType_Bhop || 
				this.lastType == JumpType_MultiBhop || 
				this.lastType == JumpType_Ladderhop || 
				this.lastType == JumpType_WeirdJump)
			 && this.jump.distance >= JS_MIN_BLOCK_DISTANCE)
		{
			// Add the player model to the distance.
			this.jump.distance += 32.0;
			
			this.CalcBlockStats(block, true);
		}
		else if (this.lastType == JumpType_LadderJump &&
				 this.jump.distance >= JS_MIN_LAJ_BLOCK_DISTANCE)
		{
			this.CalcLadderBlockStats(block, true);
		}
		else
		{
			this.failstatFailed = true;
			return;
		}
		
		if (this.jump.block > 0)
		{
			// Calculate the last stats
			this.jump.sync = float(this.syncTicks) / float(this.jump.durationTicks) * 100.0;
			this.jump.offset = failstatPosition[2] - this.takeoffOrigin[2];
			this.jump.duration = this.jump.durationTicks * GetTickInterval();
			
			// Call the callback for the reporting.
			Call_OnFailstat(this.jump);
		
			// Mark the calculation as successful
			this.failstatValid = true;
		}
		else
		{
			this.failstatFailed = true;
		}
	}
	
	
	
	// =====[ END HELPERS ]=====================================================
	
	float CalcDistance()
	{
		float distance = GetVectorHorizontalDistance(this.takeoffOrigin, this.position);
		
		// Check whether the distance is NaN
		if (distance != distance)
		{
			this.Invalidate();
			
			// We need that for the always stats
			float pos[3];
			
			// For the always stats it's ok to ignore the bug
			Movement_GetOrigin(this.jumper, pos);
			
			distance = GetVectorHorizontalDistance(this.takeoffOrigin, pos);
		}
		
		if (this.jump.originalType != JumpType_LadderJump)
		{
			distance += 32.0;
		}
		return distance;
	}
	
	void EndBlockDistance()
	{
		if ((this.jump.type == JumpType_LongJump || 
				this.jump.type == JumpType_Bhop || 
				this.jump.type == JumpType_MultiBhop || 
				this.jump.type == JumpType_Ladderhop || 
				this.jump.type == JumpType_WeirdJump)
			 && this.jump.distance >= JS_MIN_BLOCK_DISTANCE)
		{
			this.CalcBlockStats(this.position);
		}
		else if (this.jump.type == JumpType_LadderJump &&
				 this.jump.distance >= JS_MIN_LAJ_BLOCK_DISTANCE)
		{
			this.CalcLadderBlockStats(this.position);
		}
	}
	
	void EndAlwaysJumpstats()
	{
		// Only calculate that form of edge if the regular block calculations failed
		if (this.jump.block == 0 && this.jump.type != JumpType_LadderJump)
		{
			this.CalcAlwaysEdge();
		}
		
		// It's possible that the offset calculation failed with the nobug origin
		// functions, so we have to fix it when that happens. The offset shouldn't
		// be affected by the bug anyway.
		if (this.jump.offset != this.jump.offset)
		{
			Movement_GetOrigin(this.jumper, this.position);
			this.jump.offset = this.position[2] - this.takeoffOrigin[2];
		}
	}
	
	void Callback()
	{
		if (GOKZ_JS_GetOption(this.jumper, JSOption_JumpstatsAlways) == JSToggleOption_Enabled)
		{
			Call_OnJumpstatAlways(this.jump);
		}
		else
		{
			Call_OnLanding(this.jump);
		}
	}
	
	
	
	// =====[ ALWAYS FAILSTATS ]==================================================
	
	void AlwaysFailstat()
	{
		bool foundBlock;
		int coordDist, distSign;
		float traceStart[3], traceEnd[3], tracePos[3], landingPos[3], orientation[3], failOrigin[3];
		
		// Check whether the jump was already handled
		if (this.jump.type == JumpType_FullInvalid || this.failstatValid)
		{
			return;
		}
		
		// Initialize the trace boxes
		float traceMins[3] = { 0.0, 0.0, 0.0 };
		float traceLongMaxs[3] = { 0.0, 0.0, 200.0 };
		float traceShortMaxs[3] = { 0.0, 0.0, 54.0 };
		
		// Clear the stats
		this.jump.miss = 0.0;
		this.jump.distance = 0.0;
		
		// Calculate the edge
		this.CalcAlwaysEdge();
		
		// We will search for the block based on the direction the player was looking
		CopyVector(pose(0).orientation, orientation);
		
		// Get the landing orientation
		coordDist = FloatAbs(orientation[0]) < FloatAbs(orientation[1]);
		distSign = orientation[coordDist] > 0 ? 1 : -1;
		
		// Initialize the traces
		CopyVector(this.position, traceStart);
		CopyVector(this.position, traceEnd);
		
		// Assume the miss is less than 100 units
		traceEnd[coordDist] += 100.0 * distSign;
		
		// Search for the end block with the long trace
		foundBlock = TraceHullPosition(traceStart, traceEnd, traceMins, traceLongMaxs, tracePos);
		
		// If not even the long trace finds the block, we're out of luck
		if (foundBlock)
		{
			// Search for the block height
			tracePos[2] = this.position[2];
			foundBlock = this.TryFindBlockHeight(tracePos, landingPos, coordDist, distSign);
			
			// Maybe there was a headbanger, try with the short trace instead
			if (!foundBlock)
			{
				if (TraceHullPosition(traceStart, traceEnd, traceMins, traceShortMaxs, tracePos))
				{
					// Search for the height again
					tracePos[2] = this.position[2];
					foundBlock = this.TryFindBlockHeight(tracePos, landingPos, coordDist, distSign);
				}
			}
			
			if (foundBlock)
			{
				// Search for the last tick the player was above the landing block elevation.
				for (int i = 0; i < JS_FAILSTATS_MAX_TRACKED_TICKS; i++)
				{
					Pose p;
					
					// This copies it, but it shouldn't be that much of a problem
					p = pose(-i);
					
					if(p.position[2] >= landingPos[2])
					{
						// Calculate the correct fail position
						this.GetFailOrigin(landingPos[2], failOrigin, -i);
						
						// Calculate all missing stats
						this.jump.miss = FloatAbs(failOrigin[coordDist] - landingPos[coordDist]) - 16.0;
						this.jump.distance = GetVectorHorizontalDistance(failOrigin, this.takeoffOrigin);
						this.jump.offset = failOrigin[2] - this.takeoffOrigin[2];
						this.jump.durationTicks = p.durationTicks;
						this.jump.overlap = p.overlap;
						this.jump.deadair = p.deadair;
						this.jump.sync = float(p.syncTicks) / float(this.jump.durationTicks) * 100.0;
						this.jump.duration = this.jump.durationTicks * GetTickInterval();
						break;
					}
				}
			}
		}
		
		// Notify everyone about the jump
		Call_OnFailstatAlways(this.jump);
		
		// Fully invalidate the jump cause we failstatted it already
		this.jump.type = JumpType_FullInvalid;
	}
	
	void CalcAlwaysEdge()
	{
		int coordDist, distSign;
		float traceStart[3], traceEnd[3], velocity[3];
		float ladderNormal[3], ladderMins[3], ladderMaxs[3];
		
		// Ladder jumps have a different definition of edge
		if (this.jump.originalType == JumpType_LadderJump)
		{
			// Get a vector that points outwards from the lader towards the player
			GetEntPropVector(this.jumper, Prop_Send, "m_vecLadderNormal", ladderNormal);
			
			// Initialize box to search for the ladder
			if (ladderNormal[0] > ladderNormal[1])
			{
				ladderMins = view_as<float>({ 0.0, -20.0, 0.0 });
				ladderMaxs = view_as<float>({ 0.0,  20.0, 0.0 });
				coordDist = 0;
			}
			else
			{
				ladderMins = view_as<float>({ -20.0, 0.0, 0.0 });
				ladderMaxs = view_as<float>({  20.0, 0.0, 0.0 });
				coordDist = 1;
			}
			
			// The max the ladder will be away is the player model (16) + danvari tech (10) + a safety unit
			CopyVector(this.takeoffOrigin, traceEnd);
			traceEnd[coordDist] += 27.0;
			
			// Search for the ladder
			if (TraceHullPosition(this.takeoffOrigin, traceEnd, ladderMins, ladderMaxs, traceEnd))
			{
				this.jump.edge = FloatAbs(traceEnd[coordDist] - this.takeoffOrigin[coordDist]) - 16.0;
			}
		}
		else
		{
			// We calculate the orientation of the takeoff block based on what
			// direction the player was moving
			CopyVector(this.takeoffVelocity, velocity);
			this.jump.edge = -1.0;
			
			// Calculate the takeoff orientation
			coordDist = FloatAbs(velocity[0]) < FloatAbs(velocity[1]);
			distSign = velocity[coordDist] > 0 ? 1 : -1;
			
			// Make sure we hit the jumpoff block
			CopyVector(this.takeoffOrigin, traceEnd);
			traceEnd[coordDist] -= 16.0 * distSign;
			traceEnd[2] -= 1.0;
			
			// Assume a max edge of 20
			CopyVector(traceEnd, traceStart);
			traceStart[coordDist] += 20.0 * distSign;
			
			// Trace the takeoff block
			if (TraceRayPosition(traceStart, traceEnd, traceEnd))
			{
				// Check whether the trace was stuck in the block from the beginning
				if (FloatAbs(traceEnd[coordDist] - traceStart[coordDist]) > EPSILON)
				{
					this.jump.edge = FloatAbs(traceEnd[coordDist] - this.takeoffOrigin[coordDist] + 16.0 * distSign);
				}
			}
		}
	}
	
	bool TryFindBlockHeight(const float position[3], float result[3], int coordDist, int distSign)
	{
		float traceStart[3], traceEnd[3];
		
		// Setup the trace points
		CopyVector(position, traceStart);
		traceStart[coordDist] += distSign;
		CopyVector(traceStart, traceEnd);
		
		// We search in 54 unit steps
		traceStart[2] += 54.0;
		
		// We search with multiple trace starts in case the landing block has a roof
		for (int i = 0; i < 3; i += 1)
		{
			if (TraceRayPosition(traceStart, traceEnd, result))
			{
				// Make sure the trace didn't get stuck right away 
				if (FloatAbs(result[2] - traceStart[2]) > EPSILON)
				{
					result[coordDist] -= distSign;
					return true;
				}
			}
			
			// Try the next are to find the block. We use two different values to have
			// some overlap in case the block perfectly aligns with the trace.
			traceStart[2] += 54.0;
			traceEnd[2] += 53.0;
		}
		
		return false;
	}
	
	
	
	// =====[ BLOCK STATS HELPERS ]===============================================
	
	void CalcBlockStats(float landingOrigin[3], bool checkOffset = false)
	{
		int coordDist, coordDev, distSign;
		float middle[3], startBlock[3], endBlock[3], sweepBoxMin[3], sweepBoxMax[3];
		
		// Get the orientation of the block.
		GetCoordOrientation(landingOrigin, this.takeoffOrigin, coordDist, distSign);
		coordDev = !coordDist;
		
		// We can't make measurements from within an entity, so we assume the
		// player had a remotely reasonable edge and that the middle of the jump
		// is not over a block and then start measuring things out from there.
		middle[coordDist] = (this.takeoffOrigin[coordDist] + landingOrigin[coordDist]) / 2;
		middle[coordDev] = (this.takeoffOrigin[coordDev] + landingOrigin[coordDev]) / 2;
		middle[2] = this.takeoffOrigin[2] - 1.0;
		
		// Get the deviation.
		this.jump.deviation = FloatAbs(landingOrigin[coordDev] - this.takeoffOrigin[coordDev]);
		
		// Setup a sweeping line that starts in the middle and tries to search for the smallest
		// block within the deviation of the player.
		sweepBoxMin[coordDist] = 0.0;
		sweepBoxMin[coordDev] = -this.jump.deviation - 16.0;
		sweepBoxMin[2] = 0.0;
		sweepBoxMax[coordDist] = 0.0;
		sweepBoxMax[coordDev] = this.jump.deviation + 16.0;
		sweepBoxMax[2] = 0.0;
		
		// Modify the takeoff and landing origins to line up with the middle and respect
		// the bounding box of the player.
		startBlock[coordDist] = this.takeoffOrigin[coordDist] - distSign * 16.0;
		endBlock[coordDist] = landingOrigin[coordDist] + distSign * 16.0;
		startBlock[coordDev] = middle[coordDev];
		endBlock[coordDev] = middle[coordDev];
		startBlock[2] = middle[2];
		endBlock[2] = middle[2];
		
		// Search for the blocks
		if (!TraceHullPosition(middle, startBlock, sweepBoxMin, sweepBoxMax, startBlock)
			|| !TraceHullPosition(middle, endBlock, sweepBoxMin, sweepBoxMax, endBlock))
		{
			return;
		}
		
		// Make sure the edges of the blocks are parallel.
		if (!this.BlockAreEdgesParallel(startBlock, endBlock, this.jump.deviation + 32.0, coordDist, coordDev))
		{
			return;
		}
		
		// Needed for failstats, but you need the endBlock position for that, so we do it here.
		if (checkOffset)
		{
			endBlock[2] += 1.0;
			if (FloatAbs(this.FindBlockHeight(endBlock, float(distSign) * 17.0, coordDist, 1.0) - landingOrigin[2] - 0.031250) > EPSILON)
			{
				return;
			}
		}
		
		// Calculate distance and edge.
		this.jump.block = RoundFloat(FloatAbs(endBlock[coordDist] - startBlock[coordDist]));
		this.jump.edge = FloatAbs(startBlock[coordDist] - this.takeoffOrigin[coordDist] + 16.0 * distSign);
		
		// Make it easier to check for blocks that too short
		if (this.jump.block < JS_MIN_BLOCK_DISTANCE)
		{
			this.jump.block = 0;
		}
	}
	
	void CalcLadderBlockStats(float landingOrigin[3], bool checkOffset = false)
	{
		int coordDist, coordDev, distSign;
		float sweepBoxMin[3], sweepBoxMax[3], blockPosition[3], ladderPosition[3], normalVector[3], endBlock[3], middle[3];
		
		// Get the orientation of the block.
		GetCoordOrientation(landingOrigin, this.takeoffOrigin, coordDist, distSign);
		coordDev = !coordDist;
		
		// Get the deviation.
		this.jump.deviation = FloatAbs(landingOrigin[coordDev] - this.takeoffOrigin[coordDev]);
		
		// Make sure the ladder is aligned.
		GetEntPropVector(this.jumper, Prop_Send, "m_vecLadderNormal", normalVector);
		if (FloatAbs(FloatAbs(normalVector[coordDist]) - 1.0) > EPSILON)
		{
			return;
		}
		
		// Make sure we'll find the block and ladder.
		CopyVector(this.takeoffOrigin, ladderPosition);
		CopyVector(landingOrigin, endBlock);
		endBlock[2] -= 1.0;
		ladderPosition[2] = endBlock[2];
		
		// Setup a line to search for the ladder.
		sweepBoxMin[coordDist] = 0.0;
		sweepBoxMin[coordDev] = -20.0;
		sweepBoxMin[2] = 0.0;
		sweepBoxMax[coordDist] = 0.0;
		sweepBoxMax[coordDev] = 20.0;
		sweepBoxMax[2] = 0.0;
		middle[coordDist] = ladderPosition[coordDist] + distSign * JS_MIN_LAJ_BLOCK_DISTANCE;
		middle[coordDev] = endBlock[coordDev];
		middle[2] = ladderPosition[2];
		
		// Search for the ladder.
		if (!TraceHullPosition(ladderPosition, middle, sweepBoxMin, sweepBoxMax, ladderPosition))
		{
			return;
		}
		
		// Find the block and make sure it's aligned
		endBlock[coordDist] += distSign * 16.0;
		if (!TraceRayPositionNormal(middle, endBlock, blockPosition, normalVector)
			|| FloatAbs(FloatAbs(normalVector[coordDist]) - 1.0) > EPSILON)
		{
			return;
		}
		
		// Needed for failstats, but you need the blockPosition for that, so we do it here.
		if (checkOffset)
		{
			blockPosition[2] += 1.0;
			if (!this.TraceLadderOffset(this.FindBlockHeight(blockPosition, float(distSign), coordDist, 1.0) - 0.031250))
			{
				return;
			}
		}
		
		// Calculate distance and edge.
		this.jump.block = RoundFloat(FloatAbs(blockPosition[coordDist] - ladderPosition[coordDist]));
		this.jump.edge = FloatAbs(this.takeoffOrigin[coordDist] - ladderPosition[coordDist]) - 16.0;
		
		// Make it easier to check for blocks that too short
		if (this.jump.block < JS_MIN_LAJ_BLOCK_DISTANCE)
		{
			this.jump.block = 0;
		}
	}
	
	bool TraceLadderOffset(float landingHeight)
	{
		float traceOrigin[3], traceEnd[3], ladderTop[3], ladderNormal[3];
		
		// Get normal vector of the ladder.
		GetEntPropVector(this.jumper, Prop_Send, "m_vecLadderNormal", ladderNormal);
		
		// 10 units is the furthest away from the ladder surface you can get while still being on the ladder.
		traceOrigin[0] = this.takeoffOrigin[0] - 10.0 * ladderNormal[0];
		traceOrigin[1] = this.takeoffOrigin[1] - 10.0 * ladderNormal[1];
		traceOrigin[2] = this.takeoffOrigin[2] + 5;
		
		CopyVector(traceOrigin, traceEnd);
		traceEnd[2] = this.takeoffOrigin[2] - 10;
		
		// Search for the ladder
		if (!TraceHullPosition(traceOrigin, traceEnd, playerMins, playerMaxs, ladderTop)
			|| FloatAbs(ladderTop[2] - landingHeight - 0.031250) > EPSILON)
		{
			this.Invalidate();
			return false;
		}
		return true;
	}
	
	bool BlockTraceAligned(const float origin[3], const float end[3], int coordDist)
	{
		float normalVector[3];
		if (!TraceRayNormal(origin, end, normalVector))
		{
			return false;
		}
		return FloatAbs(FloatAbs(normalVector[coordDist]) - 1.0) <= EPSILON;
	}
	
	bool BlockAreEdgesParallel(const float startBlock[3], const float endBlock[3], float deviation, int coordDist, int coordDev)
	{
		float start[3], end[3], offset;
		
		// We use very short rays to find the blocks where they're supposed to be and use
		// their normals to determine whether they're parallel or not.
		offset = startBlock[coordDist] > endBlock[coordDist] ? 0.1 : -0.1;
		
		// We search for the blocks on both sides of the player, on one of the sides
		// there has to be a valid block.
		start[coordDist] = startBlock[coordDist] - offset;
		start[coordDev] = startBlock[coordDev] - deviation;
		start[2] = startBlock[2];
		
		end[coordDist] = startBlock[coordDist] + offset;
		end[coordDev] = startBlock[coordDev] - deviation;
		end[2] = startBlock[2];
		
		if (this.BlockTraceAligned(start, end, coordDist))
		{
			start[coordDist] = endBlock[coordDist] + offset;
			end[coordDist] = endBlock[coordDist] - offset;
			if (this.BlockTraceAligned(start, end, coordDist))
			{
				return true;
			}
			start[coordDist] = startBlock[coordDist] - offset;
			end[coordDist] = startBlock[coordDist] + offset;
		}
		
		start[coordDev] = startBlock[coordDev] + deviation;
		end[coordDev] = startBlock[coordDev] + deviation;
		
		if (this.BlockTraceAligned(start, end, coordDist))
		{
			start[coordDist] = endBlock[coordDist] + offset;
			end[coordDist] = endBlock[coordDist] - offset;
			if (this.BlockTraceAligned(start, end, coordDist))
			{
				return true;
			}
		}
		
		return false;
	}
	
	float FindBlockHeight(const float origin[3], float offset, int coord, float searchArea)
	{
		float block[3], traceStart[3], traceEnd[3], normalVector[3];
		
		// Setup the trace.
		CopyVector(origin, traceStart);
		traceStart[coord] += offset;
		CopyVector(traceStart, traceEnd);
		traceStart[2] += searchArea;
		traceEnd[2] -= searchArea;
		
		// Find the block height.
		if (!TraceRayPositionNormal(traceStart, traceEnd, block, normalVector)
			|| FloatAbs(normalVector[2] - 1.0) > EPSILON)
		{
			return -99999999999999999999.0; // Let's hope that's wrong enough
		}
		
		return block[2];
	}
	
	void GetFailOrigin(float planeHeight, float result[3], int poseIndex)
	{
		float newVel[3], oldVel[3];
		
		// Calculate the actual velocity.
		CopyVector(pose(poseIndex).velocity, oldVel);
		ScaleVector(oldVel, GetTickInterval());
		
		// Calculate at which percentage of the velocity vector we hit the plane.
		float scale = (planeHeight - pose(poseIndex).position[2]) / oldVel[2];
		
		// Calculate the position we hit the plane.
		CopyVector(oldVel, newVel);
		ScaleVector(newVel, scale);
		AddVectors(pose(poseIndex).position, newVel, result);
	}
}

static JumpTracker jumpTrackers[MAXPLAYERS + 1];



// =====[ HELPER FUNCTIONS ]===================================================

void GetCoordOrientation(const float vec1[3], const float vec2[3], int &coordDist, int &distSign)
{
	coordDist = FloatAbs(vec1[0] - vec2[0]) < FloatAbs(vec1[1] - vec2[1]);
	distSign = vec1[coordDist] > vec2[coordDist] ? 1 : -1;
}

bool TraceRayPosition(const float traceStart[3], const float traceEnd[3], float position[3])
{
	Handle trace = TR_TraceRayFilterEx(traceStart, traceEnd, MASK_PLAYERSOLID, RayType_EndPoint, TraceEntityFilterPlayers);
	if (TR_DidHit(trace))
	{
		TR_GetEndPosition(position, trace);
		delete trace;
		return true;
	}
	delete trace;
	return false;
}

bool TraceRayNormal(const float traceStart[3], const float traceEnd[3], float rayNormal[3])
{
	Handle trace = TR_TraceRayFilterEx(traceStart, traceEnd, MASK_PLAYERSOLID, RayType_EndPoint, TraceEntityFilterPlayers);
	if (TR_DidHit(trace))
	{
		TR_GetPlaneNormal(trace, rayNormal);
		delete trace;
		return true;
	}
	delete trace;
	return false;
}

bool TraceRayPositionNormal(const float traceStart[3], const float traceEnd[3], float position[3], float rayNormal[3])
{
	Handle trace = TR_TraceRayFilterEx(traceStart, traceEnd, MASK_PLAYERSOLID, RayType_EndPoint, TraceEntityFilterPlayers);
	if (TR_DidHit(trace))
	{
		TR_GetEndPosition(position, trace);
		TR_GetPlaneNormal(trace, rayNormal);
		delete trace;
		return true;
	}
	delete trace;
	return false;
}

bool TraceHullPosition(const float traceStart[3], const float traceEnd[3], const float mins[3], const float maxs[3], float position[3])
{
	Handle trace = TR_TraceHullFilterEx(traceStart, traceEnd, mins, maxs, MASK_PLAYERSOLID, TraceEntityFilterPlayers);
	if (TR_DidHit(trace))
	{
		TR_GetEndPosition(position, trace);
		delete trace;
		return true;
	}
	delete trace;
	return false;
}



// =====[ EVENTS ]=============================================================

void OnOptionChanged_JumpTracking(int client, const char[] option)
{
	if (StrEqual(option, gC_CoreOptionNames[Option_Mode]))
	{
		jumpTrackers[client].Invalidate();
	}
}

void OnClientPutInServer_JumpTracking(int client)
{
	entityTouchCount[client] = 0;
	jumpTrackers[client].Init(client);
}

void OnPlayerJump_JumpTracking(int client, bool jumpbug)
{
	if (jumpbug)
	{
		jumpTrackers[client].Reset(true, false, true);
		beginJumpstat[client] = true;
	}
	jumpTrackers[client].lastJumpTick = GetGameTickCount();
}

void OnJumpValidated_JumpTracking(int client, bool jumped, bool ladderJump)
{
	if (!validCmd[client])
	{
		return;
	}
	
	// We do not begin the jumpstat here but in OnPlayerRunCmdPost, because at this point
	// GOKZ_GetTakeoffSpeed does not have the correct value yet. We need this value to
	// ensure proper measurement of the first tick's sync, gain and loss, though.
	// Both events happen during the same tick, so we do not lose any measurements.
	beginJumpstat[client] = true;
	jumpTrackers[client].Reset(jumped, ladderJump, false);
}

void OnStartTouchGround_JumpTracking(int client)
{
	if (!doFailstatAlways[client])
	{
		jumpTrackers[client].End();
	}
}

void OnStartTouch_JumpTracking(int client)
{
	entityTouchCount[client]++;
	if (!Movement_GetOnGround(client))
	{
		jumpTrackers[client].Invalidate();
	}
}

void OnEndTouch_JumpTracking(int client)
{
	entityTouchCount[client]--;
}

void OnPlayerRunCmd_JumpTracking(int client, int buttons)
{
	if (!IsPlayerAlive(client))
	{
		return;
	}
	
	// Don't bother checking if player is already in air and jumpstat is already invalid
	if (Movement_GetOnGround(client) ||
		jumpTrackers[client].jump.type != JumpType_Invalid)
	{
		UpdateValidCmd(client, buttons);
	}
}

public void OnPlayerRunCmdPost_JumpTracking(int client, int cmdnum)
{
	if (!IsPlayerAlive(client))
	{
		return;
	}
	
	// Check for always failstats
	if (doFailstatAlways[client])
	{
		doFailstatAlways[client] = false;
		// Prevent TP shenanigans that would trigger failstats
		//jumpTypeLast[client] = JumpType_Invalid;
		
		if (GOKZ_JS_GetOption(client, JSOption_JumpstatsAlways) == JSToggleOption_Enabled &&
			isInAir[client])
		{
			jumpTrackers[client].AlwaysFailstat();
		}
	}
	
	if (!Movement_GetOnGround(client))
	{
		isInAir[client] = true;
	
		// First tick is done when the jumpstat begins to ensure it is measured
		if (beginJumpstat[client])
		{
			beginJumpstat[client] = false;
			jumpTrackers[client].Begin();
		}
		else
		{
			jumpTrackers[client].Update();
		}
	}
	
	if (Movement_GetOnGround(client) ||
		Movement_GetMovetype(client) == MOVETYPE_LADDER)
	{
		isInAir[client] = false;
		jumpTrackers[client].UpdateOnGround();
	}
	
	// We always have to track this, no matter if in the air or not
	jumpTrackers[client].UpdateWRelease();
}



// =====[ CHECKS ]=====

static void UpdateValidCmd(int client, int buttons)
{
	if (!CheckGravity(client)
		 || !CheckBaseVelocity(client)
		 || !CheckInWater(client)
		 || !CheckTurnButtons(buttons))
	{
		InvalidateJumpstat(client);
		validCmd[client] = false;
	}
	else
	{
		validCmd[client] = true;
	}
}

static bool CheckGravity(int client)
{
	float gravity = Movement_GetGravity(client);
	// Allow 1.0 and 0.0 gravity as both values appear during normal gameplay
	if (FloatAbs(gravity - 1.0) > EPSILON && FloatAbs(gravity) > EPSILON)
	{
		return false;
	}
	return true;
}

static bool CheckBaseVelocity(int client)
{
	float baseVelocity[3];
	Movement_GetBaseVelocity(client, baseVelocity);
	if (FloatAbs(baseVelocity[0]) > EPSILON ||
		FloatAbs(baseVelocity[1]) > EPSILON ||
		FloatAbs(baseVelocity[2]) > EPSILON)
	{
		return false;
	}
	return true;
}

static bool CheckInWater(int client)
{
	int waterLevel = GetEntProp(client, Prop_Data, "m_nWaterLevel");
	return waterLevel == 0;
}

static bool CheckTurnButtons(int buttons)
{
	// Don't allow +left or +right turns binds
	return !(buttons & (IN_LEFT | IN_RIGHT));
}



// =====[ EXTERNAL HELPER FUNCTIONS ]==========================================

void InvalidateJumpstat(int client)
{
	jumpTrackers[client].Invalidate();
}

float GetStrafeSync(Jump jump, int strafe)
{
	if (strafe < JS_MAX_TRACKED_STRAFES)
	{
		return float(jump.strafes_gainTicks[strafe]) 
			 / float(jump.strafes_ticks[strafe])
			 * 100.0;
	}
	else
	{
		return 0.0;
	}
}

float GetStrafeAirtime(Jump jump, int strafe)
{
	if (strafe < JS_MAX_TRACKED_STRAFES)
	{
		return float(jump.strafes_ticks[strafe]) 
			 / float(jump.durationTicks)
			 * 100.0;
	}
	else
	{
		return 0.0;
	}
}

void OnTeleport_FailstatAlways(int client)
{
	// We want to synchronize all of that
	doFailstatAlways[client] = true;
}
