--[[
	GunClient.lua
	LocalScript for handling gun animations and zoom mechanics

	Place this script inside the Tool (gun) or in StarterPlayerScripts
	and reference the tool accordingly.
]]

-- Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

-- Player references
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Configuration
local Config = {
	-- Movement threshold for running animation
	RunSpeedThreshold = 16,

	-- Zoom settings
	ZoomFOV = 60,
	DefaultFOV = 70,
	ZoomTweenTime = 0.2,

	-- Walk speed when aiming (to cancel sprint)
	AimingWalkSpeed = 8,
}

--------------------------------------------------------------------------------
-- ANIMATION IDS
--------------------------------------------------------------------------------

local AnimationIds = {
	-- Equip Animation
	-- TODO: Add equip animation asset ID here
	Equip = "", -- rbxassetid://YOUR_EQUIP_ANIMATION_ID_HERE

	-- Idle Animation
	Idle = "rbxassetid://77158973190136",

	-- Idle Running Animation (plays when moving fast and not falling)
	IdleRunning = "rbxassetid://109854782444751",

	-- Zoom/Aim Down Sights Animation
	-- TODO: Add zoom animation asset ID here
	Zoom = "", -- rbxassetid://YOUR_ZOOM_ANIMATION_ID_HERE
}

--------------------------------------------------------------------------------
-- STATE VARIABLES
--------------------------------------------------------------------------------

local currentTool = nil
local humanoid = nil
local animator = nil

-- Animation tracks
local equipTrack = nil
local idleTrack = nil
local idleRunningTrack = nil
local zoomTrack = nil

-- State flags
local isEquipped = false
local isZooming = false
local currentAnimationState = "none" -- "idle", "running", "none"

-- Aiming state value (for cross-script communication)
local aimingValue = nil

--------------------------------------------------------------------------------
-- ANIMATION FUNCTIONS
--------------------------------------------------------------------------------

local function loadAnimation(animationId)
	if not animator or animationId == "" then
		return nil
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

local function stopAllAnimations()
	if equipTrack and equipTrack.IsPlaying then
		equipTrack:Stop()
	end
	if idleTrack and idleTrack.IsPlaying then
		idleTrack:Stop()
	end
	if idleRunningTrack and idleRunningTrack.IsPlaying then
		idleRunningTrack:Stop()
	end
	if zoomTrack and zoomTrack.IsPlaying then
		zoomTrack:Stop()
	end
	currentAnimationState = "none"
end

local function playIdleAnimation()
	if currentAnimationState == "idle" then return end

	if idleRunningTrack and idleRunningTrack.IsPlaying then
		idleRunningTrack:Stop(0.2)
	end

	if idleTrack then
		idleTrack:Play(0.2)
		currentAnimationState = "idle"
	end
end

local function playIdleRunningAnimation()
	if currentAnimationState == "running" then return end

	if idleTrack and idleTrack.IsPlaying then
		idleTrack:Stop(0.2)
	end

	if idleRunningTrack then
		idleRunningTrack:Play(0.2)
		currentAnimationState = "running"
	end
end

--------------------------------------------------------------------------------
-- AIMING STATE MANAGEMENT
--------------------------------------------------------------------------------

local function SetAimingState(aiming)
	if not aimingValue then
		local character = player.Character
		if character then
			aimingValue = character:FindFirstChild("IsAiming")
			if not aimingValue then
				aimingValue = Instance.new("BoolValue")
				aimingValue.Name = "IsAiming"
				aimingValue.Parent = character
			end
		end
	end

	if aimingValue then
		aimingValue.Value = aiming
	end
end

local function CancelSprint()
	-- Force walk speed when aiming to cancel any sprint
	if humanoid then
		humanoid.WalkSpeed = Config.AimingWalkSpeed
	end
end

--------------------------------------------------------------------------------
-- ZOOM SYSTEM
--------------------------------------------------------------------------------

local function enableZoom()
	if isZooming then return end
	isZooming = true

	-- Set aiming state for SprintController to detect
	SetAimingState(true)

	-- Cancel sprint by setting walk speed
	CancelSprint()

	-- Tween camera FOV only (no vignette or blur)
	local tweenInfo = TweenInfo.new(Config.ZoomTweenTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local fovTween = TweenService:Create(camera, tweenInfo, {FieldOfView = Config.ZoomFOV})
	fovTween:Play()

	-- Play zoom animation if available
	--[[
	-- TODO: Uncomment when zoom animation ID is added
	if zoomTrack then
		zoomTrack:Play(0.1)
	end
	]]
end

local function disableZoom()
	if not isZooming then return end
	isZooming = false

	-- Clear aiming state
	SetAimingState(false)

	-- Tween camera FOV back
	local tweenInfo = TweenInfo.new(Config.ZoomTweenTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local fovTween = TweenService:Create(camera, tweenInfo, {FieldOfView = Config.DefaultFOV})
	fovTween:Play()

	-- Stop zoom animation if playing
	--[[
	-- TODO: Uncomment when zoom animation ID is added
	if zoomTrack and zoomTrack.IsPlaying then
		zoomTrack:Stop(0.1)
	end
	]]
end

--------------------------------------------------------------------------------
-- INPUT HANDLING
--------------------------------------------------------------------------------

local function onInputBegan(input, gameProcessed)
	if gameProcessed then return end
	if not isEquipped then return end

	-- Right mouse button for zoom
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		enableZoom()
	end
end

local function onInputEnded(input, gameProcessed)
	-- Right mouse button released
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		disableZoom()
	end
end

--------------------------------------------------------------------------------
-- MOVEMENT STATE UPDATE
--------------------------------------------------------------------------------

local function updateMovementState()
	if not isEquipped or not humanoid then return end

	-- Get current movement speed (horizontal only)
	local rootPart = humanoid.RootPart
	if not rootPart then return end

	local velocity = rootPart.AssemblyLinearVelocity
	local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude

	-- Check if player is falling (not grounded)
	local isFalling = humanoid.FloorMaterial == Enum.Material.Air

	-- Determine which animation to play
	if horizontalSpeed > Config.RunSpeedThreshold and not isFalling then
		-- Player is running and not falling - play running animation
		playIdleRunningAnimation()
	else
		-- Player is idle or falling - play idle animation
		playIdleAnimation()
	end
end

--------------------------------------------------------------------------------
-- TOOL EQUIPPED/UNEQUIPPED
--------------------------------------------------------------------------------

local function onToolEquipped()
	isEquipped = true

	-- Get humanoid and animator
	local character = player.Character
	if not character then return end

	humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	-- Create aiming state value
	aimingValue = character:FindFirstChild("IsAiming")
	if not aimingValue then
		aimingValue = Instance.new("BoolValue")
		aimingValue.Name = "IsAiming"
		aimingValue.Value = false
		aimingValue.Parent = character
	end

	-- Load animations
	idleTrack = loadAnimation(AnimationIds.Idle)
	idleRunningTrack = loadAnimation(AnimationIds.IdleRunning)

	-- Set animation properties
	-- Use Action priority so arm animations override the sprint animation's arms
	-- Since these animations only affect arms, they will layer on top of full-body animations
	if idleTrack then
		idleTrack.Looped = true
		idleTrack.Priority = Enum.AnimationPriority.Action
	end

	if idleRunningTrack then
		idleRunningTrack.Looped = true
		idleRunningTrack.Priority = Enum.AnimationPriority.Action
	end

	-- Start with idle animation
	playIdleAnimation()
end

local function onToolUnequipped()
	isEquipped = false

	-- Stop all animations
	stopAllAnimations()

	-- Disable zoom if active
	if isZooming then
		disableZoom()
	end

	-- Clean up aiming state
	if aimingValue then
		aimingValue.Value = false
	end

	-- Clean up animation tracks
	equipTrack = nil
	idleTrack = nil
	idleRunningTrack = nil
	zoomTrack = nil
end

--------------------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------------------

local function initialize(tool)
	currentTool = tool

	-- Connect tool events
	tool.Equipped:Connect(onToolEquipped)
	tool.Unequipped:Connect(onToolUnequipped)

	-- Connect input events
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)

	-- Connect to RenderStepped for movement state updates
	RunService.RenderStepped:Connect(updateMovementState)
end

--------------------------------------------------------------------------------
-- SCRIPT ENTRY POINT
--------------------------------------------------------------------------------

-- If this script is inside a Tool, use the parent as the tool
local tool = script.Parent
if tool:IsA("Tool") then
	initialize(tool)
else
	-- If not in a tool, wait for character and find equipped tool
	warn("GunClient: Script should be placed inside a Tool. Waiting for tool to be equipped...")
end
