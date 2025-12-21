--[[
	SprintController.lua
	LocalScript for handling player sprinting, landing animations, slide animations, and jump cooldown

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
	SlideAnimationId = "rbxassetid://93595842531229",
	LandingAnimationId = "rbxassetid://113014970347941",

	-- Slide settings
	SlideSpeedThreshold = 16,  -- Must be going faster than this to trigger slide
	SlideStopThreshold = 4,    -- Must slow down to below this to trigger slide
	SlideForce = 30,           -- Force applied during slide
	SlideDuration = 0.5,       -- How long the slide lasts

	-- Jump cooldown
	JumpCooldown = 2,          -- Seconds between jumps
}

-- State variables
local isSprinting = false
local shiftHeld = false
local wasInAir = false
local lastGroundSpeed = 0
local isSliding = false
local canJump = true
local lastJumpTime = 0
local releasedSprintMidAir = false  -- Track if player let go of sprint while in air
local lastMoveDirection = Vector3.new(0, 0, 0)  -- Track last move direction for slide
local airborneTime = 0  -- Track how long player has been in air (for landing intensity)

-- Animation tracks
local sprintAnimTrack = nil
local slideAnimTrack = nil
local landingAnimTrack = nil

-- Tween info
local FOVTweenInfo = TweenInfo.new(Config.FOVTweenTime, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)

--------------------------------------------------------------------------------
-- UTILITY FUNCTIONS
--------------------------------------------------------------------------------

-- Function to check if player is holding the log
local function IsHoldingLog()
	-- Check if player has the Log equipped
	local tool = Character:FindFirstChild("Log")
	if tool and tool:IsA("Tool") then
		return true
	end

	-- Also check for the invisible carrying tool
	local carryingTool = Character:FindFirstChild("CarryingLog")
	if carryingTool then
		return true
	end

	return false
end

-- Get horizontal speed (excludes vertical velocity from falling)
local function GetHorizontalSpeed()
	if not HumanoidRootPart then return 0 end
	local velocity = HumanoidRootPart.AssemblyLinearVelocity
	return Vector3.new(velocity.X, 0, velocity.Z).Magnitude
end

-- Get horizontal velocity direction
local function GetHorizontalVelocityDirection()
	if not HumanoidRootPart then return Vector3.new(0, 0, 0) end
	local velocity = HumanoidRootPart.AssemblyLinearVelocity
	local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	if horizontalVelocity.Magnitude > 0.1 then
		return horizontalVelocity.Unit
	end
	return HumanoidRootPart.CFrame.LookVector
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

local function PlaySlideAnimation()
	if isSliding then return end
	isSliding = true

	if not slideAnimTrack then
		slideAnimTrack = LoadAnimation(Config.SlideAnimationId)
		if slideAnimTrack then
			slideAnimTrack.Looped = false
			slideAnimTrack.Priority = Enum.AnimationPriority.Action2
		end
	end

	if slideAnimTrack then
		slideAnimTrack:Play(0.1)

		-- Apply slide force in the direction player was moving
		local slideDirection = GetHorizontalVelocityDirection()

		-- Create a BodyVelocity to slide the player forward
		local bodyVelocity = Instance.new("BodyVelocity")
		bodyVelocity.Name = "SlideVelocity"
		bodyVelocity.MaxForce = Vector3.new(10000, 0, 10000)
		bodyVelocity.Velocity = slideDirection * Config.SlideForce
		bodyVelocity.Parent = HumanoidRootPart

		-- Gradually reduce slide velocity and clean up
		task.spawn(function()
			local startTime = tick()
			local startVelocity = Config.SlideForce

			while tick() - startTime < Config.SlideDuration do
				local elapsed = tick() - startTime
				local progress = elapsed / Config.SlideDuration
				local currentVelocity = startVelocity * (1 - progress)
				bodyVelocity.Velocity = slideDirection * currentVelocity
				task.wait()
			end

			-- Clean up
			if bodyVelocity and bodyVelocity.Parent then
				bodyVelocity:Destroy()
			end
			isSliding = false
		end)

		-- Also set a backup cleanup in case the animation ends early
		slideAnimTrack.Stopped:Once(function()
			task.delay(0.1, function()
				local existingVelocity = HumanoidRootPart:FindFirstChild("SlideVelocity")
				if existingVelocity then
					existingVelocity:Destroy()
				end
				isSliding = false
			end)
		end)
	else
		isSliding = false
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
	-- Don't allow sprinting if holding log
	if IsHoldingLog() then
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
	-- Override the default jump behavior
	Humanoid:GetPropertyChangedSignal("Jump"):Connect(function()
		if Humanoid.Jump and not canJump then
			-- Block the jump if on cooldown
			Humanoid.Jump = false
		end
	end)

	Humanoid.StateChanged:Connect(function(oldState, newState)
		if newState == Enum.HumanoidStateType.Jumping then
			if not canJump then
				-- If somehow a jump got through while on cooldown, this shouldn't happen
				-- but we handle it just in case
				return
			end

			-- Start cooldown
			canJump = false
			lastJumpTime = tick()

			-- Re-enable jumping after cooldown
			task.delay(Config.JumpCooldown, function()
				canJump = true
			end)
		end
	end)

	-- Also connect to the Jumping event to block jumps more reliably
	Humanoid.Jumping:Connect(function(isActive)
		if isActive and not canJump then
			Humanoid.Jump = false
		end
	end)
end

-- Additional method to block jumps by setting JumpPower temporarily
local jumpPowerConnection = nil
local function EnforceJumpCooldown()
	local originalJumpPower = Humanoid.JumpPower
	local originalJumpHeight = Humanoid.JumpHeight

	RunService.Heartbeat:Connect(function()
		if not canJump then
			-- Temporarily disable jumping by setting jump power to 0
			Humanoid.JumpPower = 0
			Humanoid.JumpHeight = 0
		else
			-- Restore original jump power
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
		-- Only start sprinting if moving, on ground, AND not holding log
		local humanoidState = Humanoid:GetState()
		local isInAir = humanoidState == Enum.HumanoidStateType.Freefall or humanoidState == Enum.HumanoidStateType.Jumping

		if Humanoid.MoveDirection.Magnitude > 0 and not isInAir and not IsHoldingLog() then
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
		if isInAir then
			releasedSprintMidAir = true
			lastMoveDirection = GetHorizontalVelocityDirection()
		end

		local previousSpeed = StopSprinting()

		-- Check if we should trigger slide animation
		-- Player was running fast and now stopped (only on ground)
		local currentSpeed = GetHorizontalSpeed()

		if previousSpeed > Config.SlideSpeedThreshold and currentSpeed < Config.SlideStopThreshold and not isInAir and not isSliding then
			PlaySlideAnimation()
		end
	end
end)

--------------------------------------------------------------------------------
-- MAIN UPDATE LOOP
--------------------------------------------------------------------------------

local previousHorizontalSpeed = 0

RunService.RenderStepped:Connect(function(deltaTime)
	local humanoidState = Humanoid:GetState()
	local isInAir = humanoidState == Enum.HumanoidStateType.Freefall or humanoidState == Enum.HumanoidStateType.Jumping
	local currentHorizontalSpeed = GetHorizontalSpeed()

	-- Track airborne time for landing intensity
	if isInAir then
		airborneTime = airborneTime + deltaTime
	end

	-- Track speed while on ground (for slide detection)
	if not isInAir then
		-- Check for sudden speed decrease (slide trigger)
		-- Only trigger if not already sliding and was going fast
		if lastGroundSpeed > Config.SlideSpeedThreshold and
		   currentHorizontalSpeed < Config.SlideStopThreshold and
		   not isSliding and
		   not wasInAir then
			PlaySlideAnimation()
		end

		lastGroundSpeed = currentHorizontalSpeed
	end

	-- Stop sprinting if player picks up log while sprinting
	if isSprinting and IsHoldingLog() then
		StopSprinting()
	end

	if shiftHeld and isSprinting then
		-- Player stopped moving on ground - full stop
		if Humanoid.MoveDirection.Magnitude == 0 and not isInAir then
			local previousSpeed = lastGroundSpeed
			StopSprinting()

			-- Check for slide on stop
			if previousSpeed > Config.SlideSpeedThreshold and not isSliding then
				PlaySlideAnimation()
			end
		-- Player went airborne - only stop animation
		elseif isInAir and not wasInAir then
			StopSprintAnimation()
		-- Player landed - resume animation and check for landing animation
		elseif not isInAir and wasInAir then
			if Humanoid.MoveDirection.Magnitude > 0 then
				ResumeSprintAnimation()
			end
		end
	elseif shiftHeld and not isSprinting and Humanoid.MoveDirection.Magnitude > 0 and not isInAir and not IsHoldingLog() then
		-- Start sprinting when player lands and is moving (and not holding log)
		StartSprinting()
	end

	-- Handle landing
	if not isInAir and wasInAir then
		-- Play landing animation
		PlayLandingAnimation(airborneTime)

		-- If player released sprint mid-air and is now landing, trigger slide if they had momentum
		if releasedSprintMidAir then
			-- Check if player had significant horizontal momentum
			if lastGroundSpeed > Config.SlideSpeedThreshold and not isSliding then
				PlaySlideAnimation()
			end
			releasedSprintMidAir = false
		end

		-- Reset airborne time
		airborneTime = 0
	end

	wasInAir = isInAir
	previousHorizontalSpeed = currentHorizontalSpeed
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
	lastGroundSpeed = 0
	isSliding = false
	canJump = true
	releasedSprintMidAir = false
	lastMoveDirection = Vector3.new(0, 0, 0)
	airborneTime = 0

	-- Reset animation tracks
	sprintAnimTrack = nil
	slideAnimTrack = nil
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
	WalkBobSpeed = 8,           -- How fast the bob cycles when walking
	WalkBobIntensity = 0.03,    -- How much the camera moves when walking
	SprintBobSpeed = 12,        -- How fast the bob cycles when sprinting
	SprintBobIntensity = 0.06,  -- How much the camera moves when sprinting

	-- Landing Camera Shake
	LandingShakeEnabled = true,
	LandingShakeIntensity = 0.5,    -- Base shake intensity
	LandingShakeDuration = 0.15,    -- How long the shake lasts
	LandingShakeMaxFallTime = 2,    -- Fall time that gives maximum shake

	-- Idle Breathing (subtle camera movement when standing still)
	IdleBreathingEnabled = true,
	BreathingSpeed = 1.5,       -- How fast the breathing cycles
	BreathingIntensity = 0.01,  -- How much the camera moves

	-- Speed Lines / Motion Blur Effect (FOV pulse when accelerating)
	SpeedEffectsEnabled = true,
	AccelerationFOVPulse = 2,   -- Extra FOV added when accelerating

	-- Strafe Tilt (camera tilts slightly when strafing)
	StrafeTiltEnabled = true,
	StrafeTiltAngle = 1,        -- Maximum tilt angle in degrees
	StrafeTiltSpeed = 8,        -- How fast the tilt transitions

	-- Landing Slowdown (brief speed reduction after hard landing)
	LandingSlowdownEnabled = true,
	LandingSlowdownThreshold = 1,    -- Minimum fall time to trigger slowdown
	LandingSlowdownFactor = 0.5,     -- Speed multiplier during slowdown
	LandingSlowdownDuration = 0.3,   -- How long the slowdown lasts
}

-- Realistic effects state
local cameraBobTime = 0
local breathingTime = 0
local currentStrafeTilt = 0
local targetStrafeTilt = 0
local originalCameraCFrame = nil
local isInLandingSlowdown = false

local function ApplyCameraBob(deltaTime, speed, isRunning)
	if not RealisticEffectsConfig.CameraBobEnabled then return CFrame.new() end
	if speed < 0.5 then return CFrame.new() end

	local bobSpeed = isRunning and RealisticEffectsConfig.SprintBobSpeed or RealisticEffectsConfig.WalkBobSpeed
	local bobIntensity = isRunning and RealisticEffectsConfig.SprintBobIntensity or RealisticEffectsConfig.WalkBobIntensity

	-- Scale intensity with speed
	local speedFactor = math.clamp(speed / Config.SprintSpeed, 0, 1)
	bobIntensity = bobIntensity * speedFactor

	cameraBobTime = cameraBobTime + deltaTime * bobSpeed

	-- Create a figure-8 pattern for more realistic head bob
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

	-- Get strafe direction relative to look direction
	local moveDir = Humanoid.MoveDirection
	if moveDir.Magnitude < 0.1 then
		targetStrafeTilt = 0
	else
		local lookVector = HumanoidRootPart.CFrame.LookVector
		local rightVector = HumanoidRootPart.CFrame.RightVector

		-- Dot product with right vector gives strafe amount
		local strafeAmount = moveDir:Dot(rightVector)
		targetStrafeTilt = -strafeAmount * math.rad(RealisticEffectsConfig.StrafeTiltAngle)
	end

	-- Smoothly interpolate current tilt to target
	local tiltSpeed = RealisticEffectsConfig.StrafeTiltSpeed * deltaTime
	currentStrafeTilt = currentStrafeTilt + (targetStrafeTilt - currentStrafeTilt) * math.min(tiltSpeed, 1)

	return CFrame.Angles(0, 0, currentStrafeTilt)
end

local function ApplyLandingShake(fallDuration)
	if not RealisticEffectsConfig.LandingShakeEnabled then return end
	if fallDuration < 0.3 then return end

	-- Calculate shake intensity based on fall duration
	local normalizedFall = math.clamp(fallDuration / RealisticEffectsConfig.LandingShakeMaxFallTime, 0, 1)
	local intensity = RealisticEffectsConfig.LandingShakeIntensity * normalizedFall

	-- Apply shake over duration
	task.spawn(function()
		local startTime = tick()
		local duration = RealisticEffectsConfig.LandingShakeDuration

		while tick() - startTime < duration do
			local progress = (tick() - startTime) / duration
			local decay = 1 - progress

			-- Random shake offset
			local shakeX = (math.random() - 0.5) * 2 * intensity * decay
			local shakeY = (math.random() - 0.5) * 2 * intensity * decay

			-- Apply as camera offset (will be combined in main loop)
			-- This is handled separately since it's a one-shot effect
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

	-- Temporarily reduce walk speed
	local originalWalkSpeed = Humanoid.WalkSpeed
	local slowedSpeed = originalWalkSpeed * RealisticEffectsConfig.LandingSlowdownFactor
	Humanoid.WalkSpeed = slowedSpeed

	-- Restore after duration
	task.delay(RealisticEffectsConfig.LandingSlowdownDuration, function()
		-- Only restore if not sprinting (sprinting has its own speed)
		if not isSprinting then
			Humanoid.WalkSpeed = Config.WalkSpeed
		else
			Humanoid.WalkSpeed = Config.SprintSpeed
		end
		isInLandingSlowdown = false
	end)
end

-- Main realistic effects update (runs on RenderStepped)
local realisticEffectsConnection = nil

local function UpdateRealisticEffects(deltaTime)
	if not Camera or not Humanoid or not HumanoidRootPart then return end

	local speed = GetHorizontalSpeed()
	local humanoidState = Humanoid:GetState()
	local isInAir = humanoidState == Enum.HumanoidStateType.Freefall or humanoidState == Enum.HumanoidStateType.Jumping
	local isMoving = speed > 0.5

	-- Combine camera effects
	local cameraOffset = CFrame.new()

	if not isInAir then
		if isMoving then
			-- Apply camera bob when moving
			cameraOffset = cameraOffset * ApplyCameraBob(deltaTime, speed, isSprinting)
		else
			-- Apply idle breathing when stationary
			cameraOffset = cameraOffset * ApplyIdleBreathing(deltaTime)
			-- Reset bob time when idle for smooth transition
			cameraBobTime = 0
		end

		-- Apply strafe tilt
		cameraOffset = cameraOffset * ApplyStrafeTilt(deltaTime)
	else
		-- Reset effects when in air
		cameraBobTime = 0
		currentStrafeTilt = currentStrafeTilt * 0.95  -- Smoothly reset tilt
	end

	-- Apply combined offset to camera
	-- Note: This modifies the camera after other systems, so it layers on top
	if cameraOffset ~= CFrame.new() then
		Camera.CFrame = Camera.CFrame * cameraOffset
	end
end

-- Hook into landing for shake and slowdown effects
local function OnLandingEffects(fallDuration)
	ApplyLandingShake(fallDuration)
	ApplyLandingSlowdown(fallDuration)
end

function InitializeRealisticEffects()
	-- Disconnect previous connection if exists
	if realisticEffectsConnection then
		realisticEffectsConnection:Disconnect()
	end

	-- Reset state
	cameraBobTime = 0
	breathingTime = 0
	currentStrafeTilt = 0
	targetStrafeTilt = 0
	isInLandingSlowdown = false

	-- Connect to RenderStepped (runs after main update loop due to connection order)
	realisticEffectsConnection = RunService.RenderStepped:Connect(UpdateRealisticEffects)
end

-- Modify the landing detection to include realistic effects
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
