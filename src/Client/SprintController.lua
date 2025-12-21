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

local function PlayLandingAnimation()
	if not landingAnimTrack then
		landingAnimTrack = LoadAnimation(Config.LandingAnimationId)
		if landingAnimTrack then
			landingAnimTrack.Looped = false
			landingAnimTrack.Priority = Enum.AnimationPriority.Action
		end
	end

	if landingAnimTrack then
		landingAnimTrack:Play(0.1)
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
		local previousSpeed = StopSprinting()

		-- Check if we should trigger slide animation
		-- Player was running fast and now stopped
		local currentSpeed = GetHorizontalSpeed()
		local humanoidState = Humanoid:GetState()
		local isInAir = humanoidState == Enum.HumanoidStateType.Freefall or humanoidState == Enum.HumanoidStateType.Jumping

		if previousSpeed > Config.SlideSpeedThreshold and currentSpeed < Config.SlideStopThreshold and not isInAir and not isSliding then
			PlaySlideAnimation()
		end
	end
end)

--------------------------------------------------------------------------------
-- MAIN UPDATE LOOP
--------------------------------------------------------------------------------

local previousHorizontalSpeed = 0

RunService.RenderStepped:Connect(function()
	local humanoidState = Humanoid:GetState()
	local isInAir = humanoidState == Enum.HumanoidStateType.Freefall or humanoidState == Enum.HumanoidStateType.Jumping
	local currentHorizontalSpeed = GetHorizontalSpeed()

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

	-- Landing animation - plays when landing after being in the air
	if not isInAir and wasInAir then
		PlayLandingAnimation()
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
	wasInAir = false
	lastGroundSpeed = 0
	isSliding = false
	canJump = true

	-- Reset animation tracks
	sprintAnimTrack = nil
	slideAnimTrack = nil
	landingAnimTrack = nil

	-- Setup jump cooldown for new character
	SetupJumpCooldown()
	EnforceJumpCooldown()
end

Player.CharacterAdded:Connect(OnCharacterAdded)

-- Initial setup
SetupJumpCooldown()
EnforceJumpCooldown()
