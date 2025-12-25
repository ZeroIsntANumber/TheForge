--[[
	SprintController.lua
	LocalScript for handling player sprinting, landing animations, movement lean, and jump cooldown

	Place this script in StarterPlayerScripts
]]

-- Services
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

-- Player references
local Player = Players.LocalPlayer
local Character = Player.Character or Player.CharacterAdded:Wait()
local Humanoid = Character:WaitForChild("Humanoid")
local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")
local Camera = workspace.CurrentCamera

-- Configuration
local Config = {
	-- Speed settings
	WalkSpeed = 8,
	SprintSpeed = 24,

	-- FOV settings
	DefaultFOV = 70,
	SprintFOV = 85,
	FOVTweenTime = 0.2,

	-- Animation IDs
	SprintAnimationId = "rbxassetid://112792290502107",
	LandingAnimationId = "rbxassetid://113014970347941",

	-- Jump cooldown
	JumpCooldown = 2,          -- Seconds between jumps
}

-- State variables
local isSprinting = false
local shiftHeld = false
local wasInAir = false
local canJump = true
local lastJumpTime = 0
local airborneTime = 0  -- Track how long player has been in air (for landing intensity)
local releasedAllKeysMidAir = false  -- Track if player released all movement keys mid-air
local wasSprintingBeforeAir = false  -- Track if player was sprinting before going airborne

-- Animation tracks
local sprintAnimTrack = nil
local landingAnimTrack = nil

-- Tween info
local FOVTweenInfo = TweenInfo.new(Config.FOVTweenTime, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)

--------------------------------------------------------------------------------
-- UTILITY FUNCTIONS
--------------------------------------------------------------------------------

-- Function to check if player is holding the log
local function IsHoldingLog()
	local tool = Character:FindFirstChild("Log")
	if tool and tool:IsA("Tool") then
		return true
	end

	local carryingTool = Character:FindFirstChild("CarryingLog")
	if carryingTool then
		return true
	end

	return false
end

-- Check if player is currently aiming (set by GunClient)
local function IsAiming()
	local aimingValue = Character:FindFirstChild("IsAiming")
	return aimingValue and aimingValue.Value == true
end

-- Get horizontal speed (excludes vertical velocity from falling)
local function GetHorizontalSpeed()
	if not HumanoidRootPart then return 0 end
	local velocity = HumanoidRootPart.AssemblyLinearVelocity
	return Vector3.new(velocity.X, 0, velocity.Z).Magnitude
end

--------------------------------------------------------------------------------
-- ANIMATION FUNCTIONS
--------------------------------------------------------------------------------

local function LoadAnimation(animationId)
	if not Humanoid or animationId == "" then
		return nil
	end

	local animator = Humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = Humanoid
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = animationId

	local success, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)

	if success then
		return track
	else
		warn("Failed to load animation: " .. animationId)
		return nil
	end
end

local function PlayLandingAnimation(fallDuration)
	fallDuration = fallDuration or 0

	-- Only play landing animation if fell for a meaningful amount of time
	if fallDuration < 0.2 then
		return
	end

	if not landingAnimTrack then
		landingAnimTrack = LoadAnimation(Config.LandingAnimationId)
		if landingAnimTrack then
			landingAnimTrack.Looped = false
			landingAnimTrack.Priority = Enum.AnimationPriority.Action
		end
	end

	if landingAnimTrack then
		-- Adjust animation speed based on fall duration (harder landings = slower recovery)
		local speedMultiplier = math.clamp(1 - (fallDuration * 0.3), 0.5, 1)
		landingAnimTrack:Play(0.1)
		landingAnimTrack:AdjustSpeed(speedMultiplier)
	end
end

--------------------------------------------------------------------------------
-- SPRINT FUNCTIONS
--------------------------------------------------------------------------------

local function StopSprinting()
	if isSprinting then
		local previousSpeed = Humanoid.WalkSpeed
		isSprinting = false
		Humanoid.WalkSpeed = Config.WalkSpeed

		if sprintAnimTrack then
			sprintAnimTrack:Stop()
		end

		TweenService:Create(Camera, FOVTweenInfo, {FieldOfView = Config.DefaultFOV}):Play()

		return previousSpeed
	end
	return 0
end

local function StartSprinting()
	-- Don't allow sprinting if holding log or aiming
	if IsHoldingLog() or IsAiming() then
		return
	end

	if not isSprinting then
		isSprinting = true
		Humanoid.WalkSpeed = Config.SprintSpeed

		if not sprintAnimTrack then
			sprintAnimTrack = LoadAnimation(Config.SprintAnimationId)
			if sprintAnimTrack then
				sprintAnimTrack.Looped = true
				sprintAnimTrack.Priority = Enum.AnimationPriority.Movement
			end
		end

		if sprintAnimTrack then
			sprintAnimTrack:Play()
		end

		TweenService:Create(Camera, FOVTweenInfo, {FieldOfView = Config.SprintFOV}):Play()
	end
end

local function StopSprintAnimation()
	-- Only stops animation, keeps speed and FOV
	if sprintAnimTrack then
		sprintAnimTrack:Stop()
	end
end

local function ResumeSprintAnimation()
	-- Only resumes animation, speed and FOV already set
	if isSprinting then
		if not sprintAnimTrack then
			sprintAnimTrack = LoadAnimation(Config.SprintAnimationId)
			if sprintAnimTrack then
				sprintAnimTrack.Looped = true
				sprintAnimTrack.Priority = Enum.AnimationPriority.Movement
			end
		end

		if sprintAnimTrack then
			sprintAnimTrack:Play()
		end
	end
end

--------------------------------------------------------------------------------
-- JUMP COOLDOWN
--------------------------------------------------------------------------------

local function SetupJumpCooldown()
	Humanoid:GetPropertyChangedSignal("Jump"):Connect(function()
		if Humanoid.Jump and not canJump then
			Humanoid.Jump = false
		end
	end)

	Humanoid.StateChanged:Connect(function(oldState, newState)
		if newState == Enum.HumanoidStateType.Jumping then
			if not canJump then
				return
			end

			canJump = false
			lastJumpTime = tick()

			task.delay(Config.JumpCooldown, function()
				canJump = true
			end)
		end
	end)

	Humanoid.Jumping:Connect(function(isActive)
		if isActive and not canJump then
			Humanoid.Jump = false
		end
	end)
end

local function EnforceJumpCooldown()
	local originalJumpPower = Humanoid.JumpPower
	local originalJumpHeight = Humanoid.JumpHeight

	RunService.Heartbeat:Connect(function()
		if not canJump then
			Humanoid.JumpPower = 0
			Humanoid.JumpHeight = 0
		else
			if Humanoid.JumpPower == 0 then
				Humanoid.JumpPower = originalJumpPower
				Humanoid.JumpHeight = originalJumpHeight
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- INPUT HANDLING
--------------------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end

	if input.KeyCode == Enum.KeyCode.LeftShift then
		shiftHeld = true
		local humanoidState = Humanoid:GetState()
		local isInAir = humanoidState == Enum.HumanoidStateType.Freefall or humanoidState == Enum.HumanoidStateType.Jumping

		if Humanoid.MoveDirection.Magnitude > 0 and not isInAir and not IsHoldingLog() and not IsAiming() then
			StartSprinting()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		shiftHeld = false

		local humanoidState = Humanoid:GetState()
		local isInAir = humanoidState == Enum.HumanoidStateType.Freefall or humanoidState == Enum.HumanoidStateType.Jumping

		-- Track if we released sprint while in air
		if isInAir and isSprinting then
			wasSprintingBeforeAir = true
		end

		StopSprinting()
	end
end)

--------------------------------------------------------------------------------
-- MAIN UPDATE LOOP
--------------------------------------------------------------------------------

RunService.RenderStepped:Connect(function(deltaTime)
	local humanoidState = Humanoid:GetState()
	local isInAir = humanoidState == Enum.HumanoidStateType.Freefall or humanoidState == Enum.HumanoidStateType.Jumping
	local isMoving = Humanoid.MoveDirection.Magnitude > 0

	-- Track airborne time for landing intensity
	if isInAir then
		airborneTime = airborneTime + deltaTime

		-- Track if player releases all movement keys while in air
		if not isMoving and not shiftHeld then
			releasedAllKeysMidAir = true
		end
	end

	-- Stop sprinting if player picks up log or starts aiming while sprinting
	if isSprinting and (IsHoldingLog() or IsAiming()) then
		StopSprinting()
	end

	if shiftHeld and isSprinting then
		-- Player stopped moving on ground - full stop
		if not isMoving and not isInAir then
			StopSprinting()
		-- Player went airborne - only stop animation
		elseif isInAir and not wasInAir then
			wasSprintingBeforeAir = true
			StopSprintAnimation()
		-- Player landed - resume animation
		elseif not isInAir and wasInAir then
			if isMoving then
				ResumeSprintAnimation()
			end
		end
	elseif shiftHeld and not isSprinting and isMoving and not isInAir and not IsHoldingLog() and not IsAiming() then
		-- Start sprinting when player lands and is moving
		StartSprinting()
	end

	-- Handle landing
	if not isInAir and wasInAir then
		-- Play landing animation
		PlayLandingAnimation(airborneTime)

		-- Reset tracking flags
		releasedAllKeysMidAir = false
		wasSprintingBeforeAir = false
		airborneTime = 0
	end

	wasInAir = isInAir
end)

--------------------------------------------------------------------------------
-- CHARACTER RESPAWN HANDLING
--------------------------------------------------------------------------------

local function OnCharacterAdded(newCharacter)
	Character = newCharacter
	Humanoid = Character:WaitForChild("Humanoid")
	HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")

	-- Reset state
	isSprinting = false
	shiftHeld = false
	wasInAir = false
	canJump = true
	airborneTime = 0
	releasedAllKeysMidAir = false
	wasSprintingBeforeAir = false

	-- Reset animation tracks
	sprintAnimTrack = nil
	landingAnimTrack = nil

	-- Setup jump cooldown for new character
	SetupJumpCooldown()
	EnforceJumpCooldown()

	-- Reinitialize realistic effects for new character
	InitializeRealisticEffects()
end

Player.CharacterAdded:Connect(OnCharacterAdded)

-- Initial setup
SetupJumpCooldown()
EnforceJumpCooldown()

--------------------------------------------------------------------------------
-- REALISTIC MOVEMENT EFFECTS
-- These effects add polish and immersion to player movement.
-- All values are configurable below for easy tweaking.
--------------------------------------------------------------------------------

local RealisticEffectsConfig = {
	-- Camera Bob (subtle bounce when walking/running)
	CameraBobEnabled = true,
	WalkBobSpeed = 8,
	WalkBobIntensity = 0.03,
	SprintBobSpeed = 12,
	SprintBobIntensity = 0.06,

	-- Landing Camera Shake
	LandingShakeEnabled = true,
	LandingShakeIntensity = 0.5,
	LandingShakeDuration = 0.15,
	LandingShakeMaxFallTime = 2,

	-- Idle Breathing (subtle camera movement when standing still)
	IdleBreathingEnabled = true,
	BreathingSpeed = 1.5,
	BreathingIntensity = 0.01,

	-- Strafe Tilt (camera tilts slightly when strafing)
	StrafeTiltEnabled = true,
	StrafeTiltAngle = 1,
	StrafeTiltSpeed = 8,

	-- Landing Slowdown (brief speed reduction after hard landing)
	LandingSlowdownEnabled = true,
	LandingSlowdownThreshold = 1,
	LandingSlowdownFactor = 0.5,
	LandingSlowdownDuration = 0.3,

	-- Movement Lean (player leans in direction of movement)
	MovementLeanEnabled = true,
	MovementLeanAngle = 5,        -- Maximum lean angle in degrees
	MovementLeanSpeed = 6,        -- How fast the lean transitions
	SprintLeanMultiplier = 1.5,   -- Extra lean when sprinting
}

-- Realistic effects state
local cameraBobTime = 0
local breathingTime = 0
local currentStrafeTilt = 0
local targetStrafeTilt = 0
local isInLandingSlowdown = false

-- Movement lean state
local currentLeanX = 0  -- Forward/backward lean
local currentLeanZ = 0  -- Left/right lean
local targetLeanX = 0
local targetLeanZ = 0
local leanGyro = nil

local function ApplyCameraBob(deltaTime, speed, isRunning)
	if not RealisticEffectsConfig.CameraBobEnabled then return CFrame.new() end
	if speed < 0.5 then return CFrame.new() end

	local bobSpeed = isRunning and RealisticEffectsConfig.SprintBobSpeed or RealisticEffectsConfig.WalkBobSpeed
	local bobIntensity = isRunning and RealisticEffectsConfig.SprintBobIntensity or RealisticEffectsConfig.WalkBobIntensity

	local speedFactor = math.clamp(speed / Config.SprintSpeed, 0, 1)
	bobIntensity = bobIntensity * speedFactor

	cameraBobTime = cameraBobTime + deltaTime * bobSpeed

	local bobX = math.sin(cameraBobTime) * bobIntensity * 0.5
	local bobY = math.abs(math.sin(cameraBobTime * 2)) * bobIntensity

	return CFrame.new(bobX, bobY, 0)
end

local function ApplyIdleBreathing(deltaTime)
	if not RealisticEffectsConfig.IdleBreathingEnabled then return CFrame.new() end

	breathingTime = breathingTime + deltaTime * RealisticEffectsConfig.BreathingSpeed

	local breatheY = math.sin(breathingTime) * RealisticEffectsConfig.BreathingIntensity
	local breatheRoll = math.sin(breathingTime * 0.7) * 0.001

	return CFrame.new(0, breatheY, 0) * CFrame.Angles(0, 0, breatheRoll)
end

local function ApplyStrafeTilt(deltaTime)
	if not RealisticEffectsConfig.StrafeTiltEnabled then return CFrame.new() end
	if not HumanoidRootPart then return CFrame.new() end

	local moveDir = Humanoid.MoveDirection
	if moveDir.Magnitude < 0.1 then
		targetStrafeTilt = 0
	else
		local rightVector = HumanoidRootPart.CFrame.RightVector
		local strafeAmount = moveDir:Dot(rightVector)
		targetStrafeTilt = -strafeAmount * math.rad(RealisticEffectsConfig.StrafeTiltAngle)
	end

	local tiltSpeed = RealisticEffectsConfig.StrafeTiltSpeed * deltaTime
	currentStrafeTilt = currentStrafeTilt + (targetStrafeTilt - currentStrafeTilt) * math.min(tiltSpeed, 1)

	return CFrame.Angles(0, 0, currentStrafeTilt)
end

local function ApplyLandingShake(fallDuration)
	if not RealisticEffectsConfig.LandingShakeEnabled then return end
	if fallDuration < 0.3 then return end

	local normalizedFall = math.clamp(fallDuration / RealisticEffectsConfig.LandingShakeMaxFallTime, 0, 1)
	local intensity = RealisticEffectsConfig.LandingShakeIntensity * normalizedFall

	task.spawn(function()
		local startTime = tick()
		local duration = RealisticEffectsConfig.LandingShakeDuration

		while tick() - startTime < duration do
			local progress = (tick() - startTime) / duration
			local decay = 1 - progress

			local shakeX = (math.random() - 0.5) * 2 * intensity * decay
			local shakeY = (math.random() - 0.5) * 2 * intensity * decay

			if Camera then
				local currentCF = Camera.CFrame
				Camera.CFrame = currentCF * CFrame.Angles(math.rad(shakeY * 5), math.rad(shakeX * 5), 0)
			end

			task.wait()
		end
	end)
end

local function ApplyLandingSlowdown(fallDuration)
	if not RealisticEffectsConfig.LandingSlowdownEnabled then return end
	if fallDuration < RealisticEffectsConfig.LandingSlowdownThreshold then return end
	if isInLandingSlowdown then return end

	isInLandingSlowdown = true

	local slowedSpeed = Humanoid.WalkSpeed * RealisticEffectsConfig.LandingSlowdownFactor
	Humanoid.WalkSpeed = slowedSpeed

	task.delay(RealisticEffectsConfig.LandingSlowdownDuration, function()
		if not isSprinting then
			Humanoid.WalkSpeed = Config.WalkSpeed
		else
			Humanoid.WalkSpeed = Config.SprintSpeed
		end
		isInLandingSlowdown = false
	end)
end

local function SetupMovementLean()
	if not RealisticEffectsConfig.MovementLeanEnabled then return end
	if not HumanoidRootPart then return end

	-- Create BodyGyro for smooth lean effect
	leanGyro = HumanoidRootPart:FindFirstChild("MovementLeanGyro")
	if not leanGyro then
		leanGyro = Instance.new("BodyGyro")
		leanGyro.Name = "MovementLeanGyro"
		leanGyro.MaxTorque = Vector3.new(3000, 0, 3000)  -- Only affect X and Z rotation
		leanGyro.P = 5000
		leanGyro.D = 500
		leanGyro.Parent = HumanoidRootPart
	end
end

local function UpdateMovementLean(deltaTime)
	if not RealisticEffectsConfig.MovementLeanEnabled then return end
	if not HumanoidRootPart or not leanGyro then return end

	local moveDir = Humanoid.MoveDirection
	local humanoidState = Humanoid:GetState()
	local isInAir = humanoidState == Enum.HumanoidStateType.Freefall or humanoidState == Enum.HumanoidStateType.Jumping

	if moveDir.Magnitude < 0.1 or isInAir then
		targetLeanX = 0
		targetLeanZ = 0
	else
		-- Get movement direction relative to character facing
		local lookVector = HumanoidRootPart.CFrame.LookVector
		local rightVector = HumanoidRootPart.CFrame.RightVector

		-- Forward/backward component
		local forwardAmount = moveDir:Dot(lookVector)
		-- Left/right component
		local rightAmount = moveDir:Dot(rightVector)

		local leanMultiplier = isSprinting and RealisticEffectsConfig.SprintLeanMultiplier or 1
		local maxLean = math.rad(RealisticEffectsConfig.MovementLeanAngle) * leanMultiplier

		-- Lean forward when moving forward, backward when moving backward
		targetLeanX = forwardAmount * maxLean
		-- Lean into the turn (left when moving left, right when moving right)
		targetLeanZ = -rightAmount * maxLean
	end

	-- Smoothly interpolate current lean to target
	local leanSpeed = RealisticEffectsConfig.MovementLeanSpeed * deltaTime
	currentLeanX = currentLeanX + (targetLeanX - currentLeanX) * math.min(leanSpeed, 1)
	currentLeanZ = currentLeanZ + (targetLeanZ - targetLeanZ) * math.min(leanSpeed, 1)

	-- Apply lean via BodyGyro
	local baseCFrame = CFrame.new(HumanoidRootPart.Position) * CFrame.Angles(0, math.rad(HumanoidRootPart.Orientation.Y), 0)
	leanGyro.CFrame = baseCFrame * CFrame.Angles(currentLeanX, 0, currentLeanZ)
end

local function CleanupMovementLean()
	if leanGyro then
		leanGyro:Destroy()
		leanGyro = nil
	end
end

-- Main realistic effects update
local realisticEffectsConnection = nil

local function UpdateRealisticEffects(deltaTime)
	if not Camera or not Humanoid or not HumanoidRootPart then return end

	local speed = GetHorizontalSpeed()
	local humanoidState = Humanoid:GetState()
	local isInAir = humanoidState == Enum.HumanoidStateType.Freefall or humanoidState == Enum.HumanoidStateType.Jumping
	local isMoving = speed > 0.5

	-- Update movement lean
	UpdateMovementLean(deltaTime)

	-- Combine camera effects
	local cameraOffset = CFrame.new()

	if not isInAir then
		if isMoving then
			cameraOffset = cameraOffset * ApplyCameraBob(deltaTime, speed, isSprinting)
		else
			cameraOffset = cameraOffset * ApplyIdleBreathing(deltaTime)
			cameraBobTime = 0
		end

		cameraOffset = cameraOffset * ApplyStrafeTilt(deltaTime)
	else
		cameraBobTime = 0
		currentStrafeTilt = currentStrafeTilt * 0.95
	end

	if cameraOffset ~= CFrame.new() then
		Camera.CFrame = Camera.CFrame * cameraOffset
	end
end

local function OnLandingEffects(fallDuration)
	ApplyLandingShake(fallDuration)
	ApplyLandingSlowdown(fallDuration)
end

function InitializeRealisticEffects()
	if realisticEffectsConnection then
		realisticEffectsConnection:Disconnect()
	end

	-- Reset state
	cameraBobTime = 0
	breathingTime = 0
	currentStrafeTilt = 0
	targetStrafeTilt = 0
	isInLandingSlowdown = false
	currentLeanX = 0
	currentLeanZ = 0
	targetLeanX = 0
	targetLeanZ = 0

	-- Setup movement lean
	SetupMovementLean()

	realisticEffectsConnection = RunService.RenderStepped:Connect(UpdateRealisticEffects)
end

-- Landing effects hook
local originalWasInAir = false
RunService.Heartbeat:Connect(function(deltaTime)
	local humanoidState = Humanoid:GetState()
	local isInAir = humanoidState == Enum.HumanoidStateType.Freefall or humanoidState == Enum.HumanoidStateType.Jumping

	if not isInAir and originalWasInAir then
		OnLandingEffects(airborneTime)
	end

	originalWasInAir = isInAir
end)

-- Initialize realistic effects
InitializeRealisticEffects()
