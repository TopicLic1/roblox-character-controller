-- Connected Discord-GitHub Discord: inactiv Roblox: TopicLic1
--!strict

type Keybinds = { [string]: string }
type ActiveKeys = { [string]: boolean }
type LoadedAnimations = { [string]: AnimationTrack | { [string]: AnimationTrack } }
type Connections = { [string]: RBXScriptConnection? }

local CharacterController = {}
CharacterController.__index = CharacterController

export type CharacterController = typeof(setmetatable({} :: {
	character: Model,
	humanoid: Humanoid,
	humanoidRootPart: BasePart,
	animator: Animator,
	camera: Camera,
	
	defaultKeybinds: Keybinds,
	activeKeys: ActiveKeys,
	
	autoRun: boolean,
	
	state: string?,
	blocking: boolean,
	
	lastDash: number,
	lastSideDash: number,
	
	loadedAnimations: LoadedAnimations,
	overlayTrack: AnimationTrack?,
	track: AnimationTrack?,
	
	connections: Connections,
	inputEvent: RemoteEvent
}, CharacterController))

local players: Players = game:GetService("Players")
local lighting = game:GetService("Lighting")
local replicatedStorage: ReplicatedStorage = game:GetService("ReplicatedStorage")
local runService: RunService = game:GetService("RunService")
local userInputService: UserInputService = game:GetService("UserInputService")
local tweenService: TweenService = game:GetService("TweenService")

local player: Player? = players.LocalPlayer
local eventsFolder: Folder = replicatedStorage:WaitForChild("Events") :: Folder

function CharacterController.New(character: Model): CharacterController
	local self = setmetatable({}, CharacterController)
	
	self.character = character
	self.humanoid = character:WaitForChild("Humanoid") :: Humanoid
	self.humanoidRootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
	self.animator = self.humanoid:WaitForChild("Animator") :: Animator
	self.camera = workspace.CurrentCamera :: Camera
	
	self.defaultKeybinds = {
		Primary = "MouseButton1",
		Secondary = "MouseButton2",
		
		Run = "LeftShift",
		Emote = "B",
		Block = "F",
		Dash = "Q",
		
		Forward = "W",
		Backward = "S",
		Left = "A",
		Right = "D",
		
		Jump = "Space"
	}
	self.activeKeys = {}
	
	-- For mobile devices autoRun is enabled by default for better user convenience
	self.autoRun = userInputService.TouchEnabled and not userInputService.KeyboardEnabled
	
	self.state = nil
	self.blocking = false
	
	self.lastDash = 0
	self.lastSideDash = 0
	
	self.loadedAnimations = {}
	self.overlayTrack = nil
	self.track = nil
	
	self.connections = {}
	self.inputEvent = eventsFolder:WaitForChild("Input") :: RemoteEvent
	
	return self
end

function CharacterController:Init(): ()
	self:InitAnimations()
	self:InitConnections()
end

--[[
	Loads all animations from the "Animations" folder inside the script into the Animator
	Supports both individual animation instances and nested animation folders
]]
function CharacterController:InitAnimations(): ()
	local animationFolder = script:FindFirstChild("Animations")
	if not animationFolder then return end
	
	for _, children in ipairs(animationFolder:GetChildren()) do
		if children:IsA("Animation") then
			self.loadedAnimations[children.Name] = self.animator:LoadAnimation(children)
		elseif children:IsA("Folder") then
			local folder = {}
			self.loadedAnimations[children.Name] = folder
			
			for _, animation in pairs(children:GetChildren()) do
				if animation:IsA("Animation") then
					folder[animation.Name] = self.animator:LoadAnimation(animation)
				end
			end
		end
	end
end

function CharacterController:InitConnections(): ()
	self.connections["Died"] = self.humanoid.Died:Connect(function()
		self:StopAllAnimations()
	end)
	self.connections["AttributeChanged"] = self.character.AttributeChanged:Connect(function(attribute: string)
		self:UpdateState()
	end)
	self.connections["ChildAdded"] = self.character.ChildAdded:Connect(function(child: Instance)
		self:UpdateState()
	end)
	self.connections["ChildRemoved"] = self.character.ChildRemoved:Connect(function(child: Instance)
		self:UpdateState()
	end)
	
	--[[
		When the character is airborne we slow down the running animation playback speed
		to prevent an unnatural running on the air effect
	]]
	self.connections["FloorMaterial"] = self.humanoid:GetPropertyChangedSignal("FloorMaterial"):Connect(function()
		if self.humanoid.FloorMaterial == Enum.Material.Air then
			if self.character:GetAttribute("Running") then
				if self.track then
					self.track:AdjustSpeed(0.5)
				end
			end
		else
			if self.track then
				self.track:AdjustSpeed(1)
			end
		end
	end)
	self.connections["InputBegan"] = userInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then return end

		self:KeyUsed(input, true)
	end)
	self.connections["InputEnded"] = userInputService.InputEnded:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		self:KeyUsed(input, false)
	end)
	self.connections["RenderStepped"] = runService.RenderStepped:Connect(function(delta: number)
		self:Update(delta)
	end)
end

function CharacterController:Update(delta: number): ()
	if not self.character or not self.humanoid or self.humanoid.Health <= 0 then return end
	
	self:UpdateAnimationState()
	self:UpdateRunning()
end

-- Converts the key input into a game action using the defaultKeybinds dictionary mapping
function CharacterController:KeyUsed(input: InputObject, isDown: boolean): ()
	local key: string? = nil
	local inputName: string? = nil
	
	if input.UserInputType == Enum.UserInputType.Keyboard then
		inputName = input.KeyCode.Name
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.MouseButton2 then
		inputName = input.UserInputType.Name
	end
	
	if not inputName then return end
	
	for name, keybind in pairs(self.defaultKeybinds) do
		if keybind == inputName then
			key = name
			break
		end
	end
	
	if not key then return end
	if isDown then
		self.activeKeys[key] = true
	else
		self.activeKeys[key] = nil
	end
	
	--[[
		Dash is handled client-side to provide immediate visual feedback and zero input lag
		preventing movement delay under hight ping conditions
		The remaining actions are replicated to the server for validation and execution
	]]
	if key == "Dash" then
		if isDown then
			self:Dash()
		end
	else
		self.inputEvent:FireServer({
			Key = key,
			Down = isDown
		})
	end
end

--[[
	Determines which animation track should be playing
	based on the humanoid state and character state attributes
]]
function CharacterController:UpdateAnimationState(): ()
	local blocking: boolean = self.character:GetAttribute("Blocking")
	if blocking ~= self.blocking then
		self.blocking = blocking
		
		if blocking then
			self:PlayAnimation("overlay", "Block", 0.2, nil)
		else
			self:StopAnimation("overlay", 0.2)
		end
	end
	
	local humanoidState: Enum.HumanoidStateType = self.humanoid:GetState()
	local speed: number = self.humanoid.MoveDirection.Magnitude
	local state: string = "Idle"
	
	if self.character:GetAttribute("Running") then
		state = "Run"
	elseif humanoidState == Enum.HumanoidStateType.Freefall then
		state = "Fall"
	elseif humanoidState == Enum.HumanoidStateType.Jumping then
		state = "Jump"
	elseif speed > 0.1 then
		state = "Walk"
	end
	
	if state ~= self.state then
		self.state = state
		self:PlayAnimation("main", state, 0.2, nil)
	end
end

--[[
	Determines whether the character can enter the running state based on movement direction relative to the camera
	Uses dot product to verify that the player is actively moving forward and not
	excessively sideways or backward relative to the camera
]]
function CharacterController:UpdateRunning(): ()
	local holdingShift: boolean = self.activeKeys["Run"]
	local running = self.character:GetAttribute("Running")
	local canRun: boolean = false
	
	if self.autoRun or holdingShift then
		local forwardDot: number = self.humanoid.MoveDirection:Dot(self.camera.CFrame.LookVector)
		local rightDot: number = self.humanoid.MoveDirection:Dot(self.camera.CFrame.RightVector)
		
		--[[
			forwardDot >= -0.1 ensures the character is moving forward
			and rightDot < 0.85 prevents running if the direction leans too far sideways
		]]
		canRun = self.humanoid.MoveDirection.Magnitude > 0.1 and forwardDot >= -0.1 and math.abs(rightDot) < 0.85
	end
	
	if canRun ~= running then
		self.character:SetAttribute("Running", canRun)
		self:UpdateState()
	end
end

-- Applies speed and jump modifications based on current status constraints
function CharacterController:UpdateState(): ()
	local walkSpeed: number = 12
	local jumpPower: number = 50
	
	local running: boolean = self.character:GetAttribute("Running")
	local blocking: boolean = self.character:GetAttribute("Blocking")
	
	local attacking = self.character:FindFirstChild("Attacking")
	local ragdoll = self.character:FindFirstChild("Ragdoll")
	
	-- Prevents the character from running while actively engaged in another restricted action
	if blocking or attacking or ragdoll then
		running = false
		self.character:SetAttribute("Running", false)
	end
	
	if running then
		walkSpeed = 24
	end
	
	self.humanoid.WalkSpeed = walkSpeed
	self.humanoid.JumpPower = jumpPower
end

--[[
	Plays an animation on either the "main" or "overlay" track slot smoothly stopping any active track on the slot
	"main" slot handles base states while "overlay" handles action layers
]]
function CharacterController:PlayAnimation(slot: "main" | "overlay", name: string, fadeTime: number, subName: string?): AnimationTrack?
	local fade = fadeTime or 0.2
	local currentTrack: AnimationTrack = if slot == "main" then self.track else self.overlayTrack
	
	local track: any = self.loadedAnimations[name]
	if typeof(track) == "table" and subName then
		track = track[subName]
	end
	
	if not track then return end
	if track == currentTrack then return end
	
	if currentTrack then
		currentTrack:Stop(fade)
	end
	
	track:Play(fade)
	if slot == "main" then
		self.track = track
	else
		self.overlayTrack = track
	end
	
	return track
end

function CharacterController:StopAnimation(slot: "main" | "overlay", fadeTime: number): ()
	local fade = fadeTime or 0.2
	local currentTrack: AnimationTrack = if slot == "main" then self.track else self.overlayTrack
	if not currentTrack then return end
	
	currentTrack:Stop(fade)
	
	if slot == "main" then
		self.track = nil
	else
		self.overlayTrack = nil
	end
end


-- Stops all active animations tracks across both slots
function CharacterController:StopAllAnimations(): ()
	self:StopAnimation("main", 0.2)
	self:StopAnimation("overlay", 0.2)
end

--[[
	Implements a directional physics dash using LinearVelocity on the HumanoidRootPart
	Synchronizes physical impulse with animation markers and smoothly decelerate velocity using TweenService
]]
function CharacterController:Dash(): ()
	if self.character:FindFirstChild("Attacking") or self.character:GetAttribute("Blocking") or self.character:FindFirstChild("Ragdoll") then return end
	
	-- Clean up any lingering dash connections from previous dash to prevent memory leaks
	if self.connections["DashRenderStepped"] then
		self.connections["DashRenderStepped"]:Disconnect()
		self.connections["DashRenderStepped"] = nil :: any
	end

	if self.connections["Marker"] then
		self.connections["Marker"]:Disconnect()
		self.connections["Marker"] = nil :: any
	end
	
	local humanoidRootPart: BasePart = self.humanoidRootPart
	local camera: Camera = self.camera
	
	local linearVelocity: LinearVelocity? = nil
	
	local direction: string? = nil
	if self.activeKeys["Forward"] then
		direction = "Forward"
	elseif self.activeKeys["Backward"] then
		direction = "Backward"
	elseif self.activeKeys["Left"] then
		direction = "Left"
	elseif self.activeKeys["Right"] then
		direction = "Right"
	end
	
	if not direction then return end
	
	local now = os.clock()
	if direction == "Forward" or direction == "Backward" then
		if now - self.lastDash < 5 then return end
		self.lastDash = now
	else
		if now - self.lastSideDash < 2.5 then return end
		self.lastSideDash = now
	end
	
	local track = self:PlayAnimation("overlay", "Dash", 0.2, direction)
	if not track then return end
	
	--[[
		For non-forward dashes continuously orient the character towards camera direction
		ignoring Y axis tilt to prevent unnatural vertical rotation
	]]
	if direction ~= "Forward" then
		self.connections["DashRenderStepped"] = runService.RenderStepped:Connect(function(delta)
			humanoidRootPart.CFrame = CFrame.new(humanoidRootPart.Position, humanoidRootPart.Position + camera.CFrame.LookVector * Vector3.new(1, 0, 1))
		end)
	end
	
	--[[
		Triggers the LinearVelocity impulse when the animation reaches the "start" marker
		aligning physics acceleration directly with visual motion
	]]
	self.connections["Marker"] = track:GetMarkerReachedSignal("start"):Connect(function()
		linearVelocity = Instance.new("LinearVelocity")
		if linearVelocity then
			linearVelocity.Attachment0 = humanoidRootPart:WaitForChild("RootAttachment") :: Attachment
			linearVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
			linearVelocity.MaxAxesForce = Vector3.new(1, 0, 1) * 50000
			linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.Attachment0
			linearVelocity.Parent = humanoidRootPart
			
			if direction == "Forward" then
				linearVelocity.VectorVelocity = Vector3.new(0, 0, -100)
			elseif direction == "Backward" then
				linearVelocity.VectorVelocity = Vector3.new(0, 0, 100)
			elseif direction == "Left" then
				linearVelocity.VectorVelocity = Vector3.new(-100, 0, 0)
			elseif direction == "Right" then
				linearVelocity.VectorVelocity = Vector3.new(100, 0, 0)
			end
			
			-- Gradually decay dash velocity for natural physics dampening rather than abrupt stop
			tweenService:Create(linearVelocity, TweenInfo.new(0.5, Enum.EasingStyle.Linear, Enum.EasingDirection.Out), { VectorVelocity = Vector3.zero }):Play()
		end
	end)
	
	-- Clean up temporary physical instances and events listeners upon animation completion
	track.Stopped:Once(function()
		if linearVelocity then
			linearVelocity:Destroy()
		end
		
		if self.connections["DashRenderStepped"] then
			self.connections["DashRenderStepped"]:Disconnect()
			self.connections["DashRenderStepped"] = nil :: any
		end
		
		if self.connections["Marker"] then
			self.connections["Marker"]:Disconnect()
			self.connections["Marker"] = nil :: any
		end
	end)
end

--[[
	Disconnect all connections cleans up active tracks and
	clears local state tables upon character despawn or death to prevent memory leaks
]]
function CharacterController:Destroy(): ()
	self:StopAllAnimations()

	for _, connection in pairs(self.connections) do
		if connection then
			connection:Disconnect()
		end
	end
	
	table.clear(self.connections)
	table.clear(self.activeKeys)
	table.clear(self.defaultKeybinds)
	table.clear(self.loadedAnimations)
	
	setmetatable(self, nil)
end

local characterController: CharacterController? = nil

local function characterAdded(character: Model): ()
	if characterController then
		characterController:Destroy()
		characterController = nil
	end
	
	characterController = CharacterController.New(character)
	if characterController then
		characterController:Init()
	end
end

local function initLighting(): ()
	local gameFolder = workspace:FindFirstChild("Game")
	if gameFolder then
		for _, child in pairs(gameFolder.Map.Lighting:GetChildren()) do
			local clone = child:Clone()
			clone.Parent = lighting
		end
	end
end
initLighting()

if player then
	player.CharacterAdded:Connect(characterAdded)
	if player.Character then
		characterAdded(player.Character)
	end
end