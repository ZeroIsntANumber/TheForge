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
local Lighting = game:GetService("Lighting")

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

	-- Blur settings for vignette effect
	VignetteBlurSize = 24,
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

-- Vignette GUI elements
local vignetteGui = nil
local blurEffect = nil

--------------------------------------------------------------------------------
-- VIGNETTE BLUR EFFECT SETUP
--------------------------------------------------------------------------------

local function createVignetteGui()
	-- Create ScreenGui for vignette effect
	vignetteGui = Instance.new("ScreenGui")
	vignetteGui.Name = "GunVignetteGui"
	vignetteGui.ResetOnSpawn = false
	vignetteGui.IgnoreGuiInset = true
	vignetteGui.Enabled = false
	vignetteGui.Parent = player:WaitForChild("PlayerGui")

	-- Create the vignette frame (dark edges)
	local vignetteFrame = Instance.new("Frame")
	vignetteFrame.Name = "VignetteFrame"
	vignetteFrame.Size = UDim2.new(1, 0, 1, 0)
	vignetteFrame.Position = UDim2.new(0, 0, 0, 0)
	vignetteFrame.BackgroundTransparency = 1
	vignetteFrame.Parent = vignetteGui

	-- Create radial gradient effect using UIGradient
	local uiGradient = Instance.new("UIGradient")
	uiGradient.Name = "VignetteGradient"
	-- Radial-style vignette using transparency gradient
	uiGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),      -- Center is fully transparent
		NumberSequenceKeypoint.new(0.5, 1),    -- Still transparent
		NumberSequenceKeypoint.new(0.7, 0.8),  -- Starting to show
		NumberSequenceKeypoint.new(1, 0.3),    -- Edges are darker
	})
	uiGradient.Color = ColorSequence.new(Color3.new(0, 0, 0))
	uiGradient.Parent = vignetteFrame

	-- Set the frame to show the gradient
	vignetteFrame.BackgroundColor3 = Color3.new(0, 0, 0)
	vignetteFrame.BackgroundTransparency = 0.7

	-- Create corner darkening frames for enhanced vignette effect
	local corners = {"TopLeft", "TopRight", "BottomLeft", "BottomRight"}
	local cornerPositions = {
		TopLeft = UDim2.new(0, 0, 0, 0),
		TopRight = UDim2.new(0.5, 0, 0, 0),
		BottomLeft = UDim2.new(0, 0, 0.5, 0),
		BottomRight = UDim2.new(0.5, 0, 0.5, 0),
	}

	for _, cornerName in ipairs(corners) do
		local corner = Instance.new("Frame")
		corner.Name = cornerName
		corner.Size = UDim2.new(0.5, 0, 0.5, 0)
		corner.Position = cornerPositions[cornerName]
		corner.BackgroundColor3 = Color3.new(0, 0, 0)
		corner.BackgroundTransparency = 0.85
		corner.BorderSizePixel = 0
		corner.Parent = vignetteFrame

		local cornerGradient = Instance.new("UIGradient")
		cornerGradient.Rotation = cornerName == "TopLeft" and 135
			or cornerName == "TopRight" and 225
			or cornerName == "BottomLeft" and 45
			or 315
		cornerGradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.6, 1),
			NumberSequenceKeypoint.new(1, 0),
		})
		cornerGradient.Parent = corner
	end

	-- Create blur effect in Lighting
	blurEffect = Instance.new("BlurEffect")
	blurEffect.Name = "GunZoomBlur"
	blurEffect.Size = 0
	blurEffect.Enabled = false
	blurEffect.Parent = Lighting

	return vignetteGui
end

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

--[[
--------------------------------------------------------------------------------
-- EQUIP ANIMATION (COMMENTED OUT - ADD ASSET ID ABOVE TO ENABLE)
--------------------------------------------------------------------------------

local function playEquipAnimation()
	if equipTrack then
		-- Stop other animations temporarily
		if idleTrack and idleTrack.IsPlaying then
			idleTrack:Stop()
		end
		if idleRunningTrack and idleRunningTrack.IsPlaying then
			idleRunningTrack:Stop()
		end

		-- Play equip animation
		equipTrack:Play()

		-- Wait for equip animation to finish, then transition to idle
		equipTrack.Stopped:Wait()

		-- After equip animation, start idle
		if isEquipped then
			playIdleAnimation()
		end
	end
end
]]

--------------------------------------------------------------------------------
-- ZOOM SYSTEM
--------------------------------------------------------------------------------

local function enableZoom()
	if isZooming then return end
	isZooming = true

	-- Tween camera FOV
	local tweenInfo = TweenInfo.new(Config.ZoomTweenTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local fovTween = TweenService:Create(camera, tweenInfo, {FieldOfView = Config.ZoomFOV})
	fovTween:Play()

	-- Enable vignette effect
	if vignetteGui then
		vignetteGui.Enabled = true
	end

	-- Enable and tween blur
	if blurEffect then
		blurEffect.Enabled = true
		local blurTween = TweenService:Create(blurEffect, tweenInfo, {Size = Config.VignetteBlurSize})
		blurTween:Play()
	end

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

	-- Tween camera FOV back
	local tweenInfo = TweenInfo.new(Config.ZoomTweenTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local fovTween = TweenService:Create(camera, tweenInfo, {FieldOfView = Config.DefaultFOV})
	fovTween:Play()

	-- Tween blur out then disable
	if blurEffect then
		local blurTween = TweenService:Create(blurEffect, tweenInfo, {Size = 0})
		blurTween:Play()
		blurTween.Completed:Connect(function()
			if not isZooming then
				blurEffect.Enabled = false
			end
		end)
	end

	-- Disable vignette after tween
	task.delay(Config.ZoomTweenTime, function()
		if not isZooming and vignetteGui then
			vignetteGui.Enabled = false
		end
	end)

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

	--[[
	-- EQUIP ANIMATION (COMMENTED OUT)
	-- TODO: Add equip animation asset ID in AnimationIds.Equip to enable
	equipTrack = loadAnimation(AnimationIds.Equip)
	if equipTrack then
		equipTrack.Looped = false
		equipTrack.Priority = Enum.AnimationPriority.Action
		playEquipAnimation()
	else
		-- No equip animation, go straight to idle
		playIdleAnimation()
	end
	]]

	-- Start with idle animation (since equip is commented out)
	playIdleAnimation()

	-- Load zoom animation (commented out until ID is added)
	--[[
	-- TODO: Uncomment when zoom animation ID is added
	zoomTrack = loadAnimation(AnimationIds.Zoom)
	if zoomTrack then
		zoomTrack.Looped = true
		zoomTrack.Priority = Enum.AnimationPriority.Action
	end
	]]

	-- Create vignette GUI if not exists
	if not vignetteGui then
		createVignetteGui()
	end
end

local function onToolUnequipped()
	isEquipped = false

	-- Stop all animations
	stopAllAnimations()

	-- Disable zoom if active
	if isZooming then
		disableZoom()
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
