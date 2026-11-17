-- Connected Discord-GitHub | Discord: @noxzie8 | Roblox: @noxzie8
--!strict

-- Client-side building demo. Placement previews and ownership tags are local
-- convenience features; a real multiplayer game must validate placements on a server.
-- Trove by Stephen Leitnick (Sleitnick), from RbxUtil: https://github.com/Sleitnick/RbxUtil

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local Blocks = ReplicatedStorage:WaitForChild("Blocks")
-- Trove owns the input/render connections and the short-lived preview clone.
local Trove = require(ReplicatedStorage:WaitForChild("Trove"))
local player = Players.LocalPlayer

local GRID_SIZES = {1, 2, 4, 8}
local BUILD_RANGE = 70
local PREVIEW_LERP_SPEED = 20
local PREVIEW_TRANSPARENCY = 0.5
local COLLISION_EPSILON = 0.02
local PLACED_FOLDER_NAME = "ClientPlacedBlocks"
local PLACED_BLOCK_TAG = "DemoPlacedBlock"
local VALID_COLOR = Color3.fromRGB(70, 255, 120)
local INVALID_COLOR = Color3.fromRGB(255, 80, 80)

-- This controller uses only a small part of Trove's API. Keeping that contract
-- local gives strict typing without depending on the library's untyped API surface.
type TroveType = {
    Add: (self: TroveType, object: Instance | RBXScriptConnection) -> (Instance | RBXScriptConnection),
    Clean: (self: TroveType) -> (),
    Destroy: (self: TroveType) -> (),
    Extend: (self: TroveType) -> TroveType,
}

-- Keeping mode, selection, preview and cleanup state on one instance makes
-- switching between build and delete mode explicit.
type ControllerData = {
    _gridIndex: number,
    _blockIndex: number,
    _rotation: number,
    _rotationCFrame: CFrame,
    _baseRotation: CFrame,
    _selectedBlock: Model?,
    _preview: Model?,
    _deleteHighlight: Highlight?,
    _placedFolder: Folder,
    _placing: boolean,
    _deleting: boolean,
    _lastValidPlacement: boolean?,
    _blockSize: Vector3?,
    _pivotOffset: CFrame?,
    _visualPosition: Vector3?,
    _visualRotation: CFrame?,
    _trove: TroveType,
    _previewTrove: TroveType,
    _raycastParams: RaycastParams,
    _overlapParams: OverlapParams,
}

local PlacementController = {}
PlacementController.__index = PlacementController

-- The prototype shares methods; each controller instance owns its own mutable state.
type PlacementController = typeof(setmetatable({} :: ControllerData, PlacementController))

-- Placed clones share one folder so the workspace stays organized and startup
-- can reuse the same container if the controller is constructed again.
local function getPlacedFolder(): Folder
    local existing = workspace:FindFirstChild(PLACED_FOLDER_NAME)
    if existing then
        assert(existing:IsA("Folder"), `Workspace.{PLACED_FOLDER_NAME} must be a Folder`)
        return existing
    end

    local folder = Instance.new("Folder")
    folder.Name = PLACED_FOLDER_NAME
    folder.Parent = workspace
    return folder
end

-- The sorted direct Model children are the block list; stable ordering makes F cycle predictably.
local function getBlockTemplates(): {Model}
    local templates: {Model} = {}
    for _, child in Blocks:GetChildren() do
        if child:IsA("Model") then
            table.insert(templates, child)
        end
    end

    table.sort(templates, function(a: Model, b: Model): boolean
        return string.lower(a.Name) < string.lower(b.Name)
    end)
    return templates
end

local function getMouseHit(camera: Camera?, params: RaycastParams): RaycastResult?
    if not camera then
        return nil
    end

    -- ViewportPointToRay uses the same screen-space coordinates returned by GetMouseLocation.
    -- The shared params exclude the character and preview, while BUILD_RANGE bounds both modes.
    local mouse = UserInputService:GetMouseLocation()
    local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
    return workspace:Raycast(ray.Origin, ray.Direction * BUILD_RANGE, params)
end

local function snapToGrid(position: Vector3, gridSize: number): Vector3
    -- Snap in world axes first; ComputeTargetCFrame projects the result back onto the hit plane.
    return Vector3.new(
        math.round(position.X / gridSize) * gridSize,
        math.round(position.Y / gridSize) * gridSize,
        math.round(position.Z / gridSize) * gridSize
    )
end

local function getSupportDistance(normal: Vector3, boxFrame: CFrame, size: Vector3): number
    -- Project the oriented box's three half-axes onto the surface normal. This stays
    -- correct for rotated blocks and sloped hits, unlike using a world AABB alone.
    return math.abs(normal:Dot(boxFrame.RightVector)) * size.X * 0.5
        + math.abs(normal:Dot(boxFrame.UpVector)) * size.Y * 0.5
        + math.abs(normal:Dot(boxFrame.LookVector)) * size.Z * 0.5
end

local function preparePreview(model: Model): ()
    for _, object in model:GetDescendants() do
        if object:IsA("BaseScript") or object:IsA("ModuleScript") then
            -- Templates may contain behavior that belongs on placed models, never on a visual ghost.
            object:Destroy()
        elseif object:IsA("BasePart") then
            -- The preview is positioned by PivotTo, so physics and touch/query participation are unnecessary.
            object.Anchored = true
            object.CanCollide = false
            object.CanTouch = false
            object.CanQuery = false
            object.Massless = true
            object.Transparency = PREVIEW_TRANSPARENCY
        end
    end
end

local function setPreviewColor(model: Model?, color: Color3): ()
    if not model then
        return
    end

    for _, object in model:GetDescendants() do
        if object:IsA("BasePart") then
            object.Color = color
        end
    end
end

local function findPlacedModel(instance: Instance?): Model?
    -- Rays usually hit a part, not its containing model. The tag and owner attribute are checked
    -- here so highlighting and deletion use the same target rules.
    local current = instance
    while current and current ~= workspace do
        if current:IsA("Model")
            and CollectionService:HasTag(current, PLACED_BLOCK_TAG)
            and current:GetAttribute("PlacedByUserId") == player.UserId
        then
            return current
        end
        current = current.Parent
    end
    return nil
end

function PlacementController.new(): PlacementController
    -- The parent Trove owns controller lifetime; its child scope can replace previews
    -- without disconnecting the input and render callbacks.
    local trove = Trove.new() :: TroveType
    local previewTrove: TroveType = trove:Extend()
    local self = setmetatable({
        _gridIndex = 1,
        _blockIndex = 0,
        _rotation = 0,
        _rotationCFrame = CFrame.new(),
        _baseRotation = CFrame.new(),
        _selectedBlock = nil,
        _preview = nil,
        _deleteHighlight = nil,
        _placedFolder = getPlacedFolder(),
        _placing = false,
        _deleting = false,
        _lastValidPlacement = nil,
        _blockSize = nil,
        _pivotOffset = nil,
        _visualPosition = nil,
        _visualRotation = nil,
        _trove = trove,
        _previewTrove = previewTrove,
        _raycastParams = RaycastParams.new(),
        _overlapParams = OverlapParams.new(),
    } :: ControllerData, PlacementController) :: PlacementController

    -- Exclusion keeps the rest of the world targetable by default; UpdateFilters adds
    -- only the local character and preview that must not interfere with either query.
    self._raycastParams.FilterType = Enum.RaycastFilterType.Exclude
    self._raycastParams.IgnoreWater = true
    self._overlapParams.FilterType = Enum.RaycastFilterType.Exclude
    -- Zero means the query is not silently truncated. A result cap could otherwise
    -- omit a collidable part and incorrectly mark a crowded position as clear.
    self._overlapParams.MaxParts = 0
    -- RespectCanCollide filters by CanCollide instead of CanQuery, so decorative
    -- non-collidable parts do not veto an otherwise clear placement.
    self._overlapParams.RespectCanCollide = true

    -- A single reusable outline avoids creating highlights while the pointer moves.
    local highlight = Instance.new("Highlight")
    highlight.FillTransparency = 1
    highlight.OutlineColor = INVALID_COLOR
    highlight.DepthMode = Enum.HighlightDepthMode.Occluded
    highlight.Enabled = false
    highlight.Parent = workspace
    self._deleteHighlight = highlight
    self._trove:Add(highlight)

    self:Start()
    return self
end

function PlacementController.UpdateFilters(self: PlacementController): ()
    -- Refresh on preview creation and respawn, then use the same exclusions for aiming
    -- and occupancy so the player and their ghost cannot target or block themselves.
    local exclusions: {Instance} = {}
    if self._preview then
        table.insert(exclusions, self._preview)
    end
    local character = player.Character
    if character then
        table.insert(exclusions, character)
    end
    self._raycastParams.FilterDescendantsInstances = exclusions
    self._overlapParams.FilterDescendantsInstances = exclusions
end

function PlacementController.Start(self: PlacementController): ()
    -- RenderStepped drives visual updates, input changes state, and Trove owns each
    -- connection so Destroy can disconnect the controller as one unit.
    self._trove:Add(RunService.RenderStepped:Connect(function(deltaTime: number): ()
        self:Update(deltaTime)
    end))

    self._trove:Add(UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean): ()
        -- Leave chat and UI controls alone; building shortcuts only handle unused input.
        if gameProcessed or UserInputService:GetFocusedTextBox() then
            return
        end
        self:ProcessInput(input)
    end))

    self._trove:Add(player.CharacterAdded:Connect(function(): ()
        self:UpdateFilters()
    end))
    self:UpdateFilters()
end

function PlacementController.ProcessInput(self: PlacementController, input: InputObject): ()
    -- Mouse clicks are routed by the active mode. Q cancels a preview while building
    -- and restores the last selected template when the controller is idle.
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        if self._deleting then
            self:Delete()
        else
            self:Place()
        end
    elseif input.KeyCode == Enum.KeyCode.F and self._placing then
        self:CycleBlock()
    elseif input.KeyCode == Enum.KeyCode.R and self._placing then
        self:Rotate()
    elseif input.KeyCode == Enum.KeyCode.G and self._placing then
        self:CycleGridSize()
    elseif input.KeyCode == Enum.KeyCode.X then
        self:ToggleDeleteMode()
    elseif input.KeyCode == Enum.KeyCode.Q then
        if self._placing then
            self:Cancel()
        else
            self:EquipLastBlock()
        end
    end
end

function PlacementController.EquipLastBlock(self: PlacementController): ()
    local templates = getBlockTemplates()
    if #templates == 0 then
        warn("No Model templates were found inside ReplicatedStorage.Blocks")
        return
    end

    if self._blockIndex < 1 or self._blockIndex > #templates then
        self._blockIndex = 1
    end
    -- Both Q and F finish through SelectBlock, keeping preview setup identical.
    self:SelectBlock(templates[self._blockIndex])
end

function PlacementController.CycleBlock(self: PlacementController): ()
    local templates = getBlockTemplates()
    if #templates == 0 then
        warn("No Model templates were found inside ReplicatedStorage.Blocks")
        self:Cancel()
        return
    end

    self._blockIndex = (self._blockIndex % #templates) + 1
    self:SelectBlock(templates[self._blockIndex])
end

function PlacementController.SelectBlock(self: PlacementController, template: Model): ()
    if not template:IsDescendantOf(Blocks) then
        warn("Selected block must be a child of ReplicatedStorage.Blocks")
        return
    end

    local hasPart = false
    for _, object in template:GetDescendants() do
        if object:IsA("BasePart") then
            hasPart = true
            break
        end
    end
    if not hasPart then
        warn(`Block template "{template.Name}" has no BaseParts`)
        return
    end

    self:Cancel()
    self._selectedBlock = template
    self._placing = true
    -- Cache bounds at selection time; the render loop reuses their dimensions and
    -- box-to-pivot relationship instead of querying the model every frame.
    local boundsFrame, boundsSize = template:GetBoundingBox()
    self._blockSize = boundsSize
    -- Keep the template's authored pivot orientation; the player's yaw is composed with it later.
    self._baseRotation = boundsFrame.Rotation
    -- Placement targets the bounding box, while PivotTo expects the model pivot.
    self._pivotOffset = boundsFrame:ToObjectSpace(template:GetPivot())
    self:CreatePreview(template)
end

function PlacementController.CycleGridSize(self: PlacementController): ()
    self._gridIndex = (self._gridIndex % #GRID_SIZES) + 1
end

function PlacementController.ToggleDeleteMode(self: PlacementController): ()
    local deleting = not self._deleting
    self:Cancel()
    self._deleting = deleting
end

function PlacementController.CreatePreview(self: PlacementController, template: Model): ()
    -- Replace only the temporary clone; the selected template stays in ReplicatedStorage
    -- so preview settings never leak into blocks later cloned for placement.
    self._previewTrove:Clean()
    local preview = template:Clone()
    preparePreview(preview)
    self._preview = preview
    self._previewTrove:Add(preview)
    self._rotation = 0
    self._rotationCFrame = CFrame.new()
    self._visualPosition = nil
    self._visualRotation = nil
    self._lastValidPlacement = nil
    self._placing = true
    self:UpdateFilters()
end

function PlacementController.Rotate(self: PlacementController): ()
    -- Store the quarter-turn as a CFrame so it composes directly with the cached
    -- template orientation when the next target is calculated.
    self._rotation = (self._rotation + 90) % 360
    self._rotationCFrame = CFrame.Angles(0, math.rad(self._rotation), 0)
end

function PlacementController.CanPlace(self: PlacementController): boolean
    -- Update and Place share this guard so neither uses incomplete selection state.
    return self._placing
        and self._preview ~= nil
        and self._selectedBlock ~= nil
        and self._blockSize ~= nil
        and self._pivotOffset ~= nil
end

function PlacementController.CheckCollisions(
    self: PlacementController,
    boxFrame: CFrame,
    size: Vector3
): boolean
    -- This is a fast oriented bounds query. The small inset allows face-to-face
    -- contact; GetPartBoundsInBox can still conservatively report some mesh overlaps.
    local checkSize = Vector3.new(
        size.X - math.min(COLLISION_EPSILON, size.X * 0.1),
        size.Y - math.min(COLLISION_EPSILON, size.Y * 0.1),
        size.Z - math.min(COLLISION_EPSILON, size.Z * 0.1)
    )
    local parts = workspace:GetPartBoundsInBox(boxFrame, checkSize, self._overlapParams)
    for _, part in parts do
        if part.CanCollide then
            return false
        end
    end
    return true
end

function PlacementController.ComputeTargetCFrame(
    self: PlacementController,
    result: RaycastResult
): (CFrame, Vector3)
    local size = assert(self._blockSize, "Block size is required before computing placement")
    local gridSize = GRID_SIZES[self._gridIndex]
    -- Add player yaw around world Y without discarding rotation authored into the template.
    local boxRotation = self._rotationCFrame * self._baseRotation
    local targetOrientation = CFrame.new(result.Position) * boxRotation

    -- Snap in world space, then move the snapped point back onto the actual hit
    -- plane. This preserves contact on slopes where independent XYZ rounding drifts.
    local snappedPoint = snapToGrid(result.Position, gridSize)
    local planeCorrection = (result.Position - snappedPoint):Dot(result.Normal)
    local surfacePoint = snappedPoint + result.Normal * planeCorrection
    local offset = getSupportDistance(result.Normal, targetOrientation, size)
    local boxPosition = surfacePoint + result.Normal * offset
    local targetFrame = CFrame.new(boxPosition) * boxRotation

    -- The overlap query uses this same oriented frame, so it needs the original
    -- local dimensions rather than a world-aligned size that would be rotated twice.
    return targetFrame, size
end

function PlacementController.UpdatePreviewTransform(
    self: PlacementController,
    targetFrame: CFrame,
    deltaTime: number
): ()
    -- Exponential easing responds similarly across frame rates. Only the ghost is
    -- smoothed; collision checks and Place use the exact target calculated this frame.
    local alpha = 1 - math.exp(-PREVIEW_LERP_SPEED * deltaTime)
    local targetPosition = targetFrame.Position
    if self._visualPosition then
        self._visualPosition = self._visualPosition:Lerp(targetPosition, alpha)
    else
        self._visualPosition = targetPosition
    end

    if self._visualRotation then
        self._visualRotation = self._visualRotation:Lerp(targetFrame.Rotation, alpha)
    else
        self._visualRotation = targetFrame.Rotation
    end

    local preview = self._preview
    local pivotOffset = self._pivotOffset
    local visualPosition = self._visualPosition
    local visualRotation = self._visualRotation
    if not preview or not pivotOffset or not visualPosition or not visualRotation then
        return
    end
    preview:PivotTo(CFrame.new(visualPosition) * visualRotation * pivotOffset)
end

function PlacementController.UpdateDeleteMode(self: PlacementController): ()
    -- The highlight is feedback only; Delete raycasts and checks ownership again on click.
    local highlight = self._deleteHighlight
    if not self._deleting or not highlight then
        return
    end

    local result = getMouseHit(workspace.CurrentCamera, self._raycastParams)
    local target = if result then findPlacedModel(result.Instance) else nil
    if highlight.Adornee ~= target then
        highlight.Adornee = target
        highlight.Enabled = target ~= nil
    end
end

function PlacementController.Update(self: PlacementController, deltaTime: number): ()
    -- Deletion needs only a selectable target. Building uses one fresh target for both
    -- the visual ghost and the overlap check, keeping their feedback in sync.
    if self._deleting then
        self:UpdateDeleteMode()
        return
    end
    if not self:CanPlace() then
        return
    end

    local preview = self._preview
    local result = getMouseHit(workspace.CurrentCamera, self._raycastParams)
    if not result then
        -- Hide the ghost and clear the validity state so a click cannot reuse an old target.
        if preview then
            preview.Parent = nil
        end
        if self._lastValidPlacement ~= false then
            self._lastValidPlacement = false
            setPreviewColor(preview, INVALID_COLOR)
        end
        return
    end

    if preview and preview.Parent ~= workspace then
        preview.Parent = workspace
    end
    local targetFrame, worldSize = self:ComputeTargetCFrame(result)
    self:UpdatePreviewTransform(targetFrame, deltaTime)
    local canPlace = self:CheckCollisions(targetFrame, worldSize)
    -- Recolor only when validity changes; walking every preview part each frame is unnecessary.
    if self._lastValidPlacement ~= canPlace then
        self._lastValidPlacement = canPlace
        setPreviewColor(preview, if canPlace then VALID_COLOR else INVALID_COLOR)
    end
end

function PlacementController.Place(self: PlacementController): ()
    if not self:CanPlace() then
        return
    end

    -- Input can arrive between rendered frames, so validate the current pointer
    -- and collision result again instead of trusting a stale green preview.
    local result = getMouseHit(workspace.CurrentCamera, self._raycastParams)
    if not result then
        return
    end
    local targetFrame, worldSize = self:ComputeTargetCFrame(result)
    if not self:CheckCollisions(targetFrame, worldSize) then
        return
    end

    local template = self._selectedBlock
    local pivotOffset = self._pivotOffset
    if not template or not pivotOffset or not template:IsDescendantOf(Blocks) then
        return
    end
    local placedModel = template:Clone()
    -- Selection cached the box-to-pivot offset; applying it here places the model pivot
    -- while keeping the clone's bounding box at the exact frame that passed validation.
    placedModel:PivotTo(targetFrame * pivotOffset)
    -- Building pieces should remain on the snapped grid. Anchor only the clone so
    -- the shared template keeps its authored physics settings.
    for _, object in placedModel:GetDescendants() do
        if object:IsA("BasePart") then
            object.Anchored = true
        end
    end
    -- These tags and attributes support this demo's local delete/highlight flow only;
    -- clients can forge them, so they are not a multiplayer ownership boundary.
    placedModel:SetAttribute("PlacedByUserId", player.UserId)
    placedModel:SetAttribute("PlacedFromTemplate", template.Name)
    CollectionService:AddTag(placedModel, PLACED_BLOCK_TAG)
    placedModel.Parent = self._placedFolder
end

function PlacementController.Delete(self: PlacementController): ()
    if not self._deleting then
        return
    end
    -- Never let the last highlighted instance authorize deletion after the pointer moves.
    local result = getMouseHit(workspace.CurrentCamera, self._raycastParams)
    local target = if result then findPlacedModel(result.Instance) else nil
    if target then
        target:Destroy()
        local highlight = self._deleteHighlight
        if highlight then
            highlight.Adornee = nil
            highlight.Enabled = false
        end
    end
end

function PlacementController.Cancel(self: PlacementController): ()
    -- Cancel clears temporary mode and preview state but leaves persistent controller
    -- connections and the reusable highlight ready for the next selection.
    self._placing = false
    self._deleting = false
    self._selectedBlock = nil
    self._preview = nil
    self._lastValidPlacement = nil
    self._blockSize = nil
    self._pivotOffset = nil
    self._visualPosition = nil
    self._visualRotation = nil
    self._previewTrove:Clean()
    self:UpdateFilters()

    local highlight = self._deleteHighlight
    if highlight then
        highlight.Enabled = false
        highlight.Adornee = nil
    end
end

function PlacementController.Destroy(self: PlacementController): ()
    -- Remove the active preview first, then let the parent Trove disconnect events and
    -- destroy the remaining controller-owned instance.
    self:Cancel()
    self._trove:Destroy()
end

local controller = PlacementController.new()
return controller
