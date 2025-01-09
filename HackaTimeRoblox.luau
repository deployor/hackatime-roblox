local HttpService = game:GetService("HttpService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService") -- play test detection
local EDITOR_NAME = "Roblox Studio"


-- Simple OS detection
local function detectOperatingSystem()
    -- check for Command/Meta key to detect Mac
    local isMac = false
    pcall(function()
        local UserInputService = game:GetService("UserInputService")
        isMac = UserInputService.KeyboardEnabled and
                (UserInputService:IsKeyDown(Enum.KeyCode.LeftMeta) or
                        UserInputService:IsKeyDown(Enum.KeyCode.RightMeta))
    end)
    return isMac and "darwin" or "Windows"
end

-- OS settings
local function getStoredOS()
    return plugin:GetSetting("OverrideOS") or detectOperatingSystem()
end

local APIEndpoint = "https://waka.hackclub.com/api/users/current/heartbeats.bulk"
local HeartbeatQueue = {}
local HeartbeatInterval = 60
local LastTypingTime = os.time()
local WakaTimeAPIKey = ""
local IsOffline = false

local IdleTimeout = 100
local LastActivityTime = os.time()
local CurrentProject

local TRACK_PLAY_TESTING = true -- Toggle for play testing tracking (only server)

local isPlayTesting = false

-- mouse movement tracking variables
local lastMousePosition = Vector2.new(0, 0)
local hasMouseMoved = false
local UserInputService = game:GetService("UserInputService")

-- OS and machine tracking
local OS_TYPE = getStoredOS()
local MACHINE_ID = ""

-- Function to generate/load machine ID
local function getMachineId()
    local savedId = plugin:GetSetting("MachineId")
    if savedId then
        return savedId
    end

    -- Generate new machine ID if none exists
    local id = HttpService:GenerateGUID(false)
    plugin:SetSetting("MachineId", id)
    return id
end

-- Initialize machine ID
MACHINE_ID = getMachineId()

-- line tracking variables
local lastFileContents = {}

local function trackLineChanges(filename, newContent, cursorPosition)
    local oldContent = lastFileContents[filename] or ""
    if oldContent == newContent then
        return {
            additions = 0,
            deletions = 0,
            total_lines = #string.split(newContent, "\n"),
            cursor_line = cursorPosition.Line or 1,
            cursor_column = cursorPosition.Character or 1
        }
    end

    local oldLines = string.split(oldContent, "\n")
    local newLines = string.split(newContent, "\n")

    local additions = 0
    local deletions = 0

    -- First count pure additions/deletions from line count difference
    local lineDiff = #newLines - #oldLines
    if lineDiff > 0 then
        additions = additions + lineDiff
    elseif lineDiff < 0 then
        deletions = deletions - lineDiff
    end

    -- Then count modified lines
    local minLen = math.min(#oldLines, #newLines)
    for i = 1, minLen do
        if oldLines[i] ~= newLines[i] then
            -- If line content changed, count as one change
            local oldLen = #oldLines[i]
            local newLen = #newLines[i]
            if newLen > oldLen then
                additions = additions + 1
            elseif newLen < oldLen then
                deletions = deletions + 1
            else
                -- If same length but different content, count as both
                additions = additions + 1
                deletions = deletions + 1
            end
        end
    end

    lastFileContents[filename] = newContent
    return {
        additions = additions,
        deletions = deletions,
        total_lines = #newLines,
        cursor_line = cursorPosition.Line or 1,
        cursor_column = cursorPosition.Character or 1
    }
end

-- mouse movement detection
UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement then
        local newPosition = Vector2.new(input.Position.X, input.Position.Y)
        if (newPosition - lastMousePosition).Magnitude > 5 then
            -- 5 pixels
            hasMouseMoved = true
            lastMousePosition = newPosition
        end
    end
end)

local persistQueue
local sendHeartbeats
local saveAPIKey
local loadAPIKey
local tokenInput

-- Add near other global variables
local WAKATIME_ID_KEY = "WakaTimeProjectId"
local projectLabel = nil  -- Add this global variable

-- Forward declare functions to avoid reference issues
local getCurrentProjectName
local refreshProjectName

refreshProjectName = function()
    CurrentProject = getCurrentProjectName()
    if projectLabel then
        projectLabel.Text = "Project: " .. CurrentProject
    end
end

getCurrentProjectName = function()
    -- Try to find existing project ID first
    local storedId = game:GetService("ReplicatedStorage"):FindFirstChild(WAKATIME_ID_KEY)
    if storedId and storedId:IsA("StringValue") and storedId.Value ~= "" then
        return storedId.Value -- Use stored ID directly without prefix
    end

    -- Default names to ignore
    local defaultNames = {
        ["Game"] = true,
        ["Workspace"] = true,
        ["StarterPlayer"] = true,
        ["ReplicatedFirst"] = true,
        ["BaseGame"] = true,
        ["TestPlace"] = true,
        ["Project"] = true,
        ["Untitled"] = true,
        [""] = true
    }
    
    local projectName = nil
    
    -- Try getting from MarketplaceService first (published games)
    pcall(function()
        local info = MarketplaceService:GetProductInfo(game.PlaceId)
        if info and info.Name and not defaultNames[info.Name] then
            projectName = info.Name
        end
    end)
    
    -- Try getting from DataModel name if no marketplace name
    if not projectName and not defaultNames[game.Name] then
        projectName = game.Name
    end
    
    -- Try getting workspace name if still no name
    if not projectName and not defaultNames[workspace.Name] then
        projectName = workspace.Name
    end
    
    -- Use place ID if available and no other name found
    if not projectName and game.PlaceId and game.PlaceId > 0 then
        projectName = "Place" .. tostring(game.PlaceId)
    end
    
    -- If we found a valid name, store and use it
    if projectName then
        local idValue = Instance.new("StringValue")
        idValue.Name = WAKATIME_ID_KEY
        idValue.Value = projectName
        
        -- Try to store in ReplicatedStorage
        pcall(function()
            idValue.Parent = game:GetService("ReplicatedStorage")
            
            -- Add explanation comment
            local comment = Instance.new("Message")
            comment.Parent = idValue
            comment.Text = "This is a WakaTime project identifier. Please don't delete it - it helps track your coding time consistently."
        end)
        
        return projectName
    end
    
    -- Last resort: generate random ID
    local newId = HttpService:GenerateGUID(false):sub(1, 8)
    local idValue = Instance.new("StringValue")
    idValue.Name = WAKATIME_ID_KEY
    idValue.Value = "RoProject-" .. newId
    
    pcall(function()
        idValue.Parent = game:GetService("ReplicatedStorage")
        
        -- Add explanation comment
        local comment = Instance.new("Message")
        comment.Parent = idValue
        comment.Text = "This is a WakaTime project identifier. Please don't delete it - it helps track your coding time consistently."
    end)
    
    return "RoProject-" .. newId
end

-- Set the current project name, with improved fallbacks
CurrentProject = getCurrentProjectName()  -- Updated function call

--- Toolbar and Button Setup ---
local toolbar = plugin:CreateToolbar("WakaTime Plugin")
local settingsButton = toolbar:CreateButton("HackaTime", "Open HackaTime Plugin GUI", "rbxassetid://85649168710314")
settingsButton.ClickableWhenViewportHidden = true

--- API Key Management ---
loadAPIKey = function()
    local success, result = pcall(function()
        return plugin:GetSetting("WakaTimeAPIKey")
    end)
    if success and result and result ~= "" then
        WakaTimeAPIKey = result
        print("API key loaded successfully.")
        spawn(function()
            wait(5) -- Small delay to ensure everything is initialized (if u ur pic is even lower than 5, u suck)
            sendHeartbeats()
        end)
    else
        WakaTimeAPIKey = ""
        print("No API key found. Please set it using the plugin settings.")
    end
end

saveAPIKey = function(apiKey)
    local success, errorMsg = pcall(function()
        plugin:SetSetting("WakaTimeAPIKey", apiKey)
        WakaTimeAPIKey = apiKey
    end)
    if success then
        print("API key saved successfully!")
        spawn(function()
            sendHeartbeats()
        end)
    else
        warn("Error saving API key: " .. tostring(errorMsg))
    end
end

--- Queue Persistence ---
persistQueue = function()
    local success, err = pcall(function()
        if #HeartbeatQueue > 0 then
            plugin:SetSetting("HeartbeatQueue", HttpService:JSONEncode(HeartbeatQueue))
            plugin:SetSetting("LastSaveTime", os.time())
        else
            plugin:SetSetting("HeartbeatQueue", nil)
            plugin:SetSetting("LastSaveTime", nil)
        end
    end)
    if not success then
        warn("Failed to persist heartbeat queue: " .. tostring(err))
    end
end

local function loadQueue()
    local success, result = pcall(function()
        local savedQueue = plugin:GetSetting("HeartbeatQueue")
        local lastSaveTime = plugin:GetSetting("LastSaveTime")

        if savedQueue and lastSaveTime then
            -- Check if saved queue is not too old (10 days since then ya might cheat)
            if os.time() - lastSaveTime < 864000 then
                return HttpService:JSONDecode(savedQueue)
            end
        end
        return {}
    end)

    if success and result then
        HeartbeatQueue = result
        print("Heartbeat queue loaded. Items in queue: " .. #HeartbeatQueue)
        spawn(function()
            wait(10)
            sendHeartbeats()
        end)
    else
        HeartbeatQueue = {}
        print("No saved heartbeat queue found or failed to load.")
    end
end

-- Function to create a heartbeat
local function createHeartbeat(scriptName, activity, lineInfo)
    return {
        type = activity or "coding",
        time = os.time(),
        entity = scriptName,
        category = activity or "coding",
        project = CurrentProject,
        editor = EDITOR_NAME,
        language = "lua",
        is_write = false,
        lines = lineInfo.total_lines,
        lineno = lineInfo.cursor_line,
        cursorpos = lineInfo.cursor_column,
        line_additions = lineInfo.additions,
        line_deletions = lineInfo.deletions,
        machine_name_id = MACHINE_ID,
        operating_system = OS_TYPE,
        project_root_count = 1,
        branch = "main",
        user_agent = "roblox-studio-wakatime/1.0"
    }
end

-- Function to add heartbeat to queue
local function addHeartbeat(scriptName, activity)
    if os.time() - LastTypingTime >= HeartbeatInterval then
        local heartbeat = createHeartbeat(scriptName, activity)
        table.insert(HeartbeatQueue, heartbeat)
        LastTypingTime = os.time()
        LastActivityTime = os.time()
        persistQueue()
    end
end

local function isConsole(document)
    local name = document.Name and document.Name:lower() or ""
    return name:match("output") or name:match("console")
end

ScriptEditorService.TextDocumentDidChange:Connect(function(document)
    if isConsole(document) then
        return
    end

    local scriptName = document.Name or "Unnamed Script"

    local success, source = pcall(function()
        return document:GetText()
    end)

    if success then
        local cursorPosition = {
            Line = 1,
            Character = 1
        }

        pcall(function()
            local selection = document.Selection
            if selection then
                cursorPosition.Line = selection.Line
                cursorPosition.Character = selection.Character
            end
        end)

        local lineInfo = trackLineChanges(scriptName, source, cursorPosition)

        if os.time() - LastTypingTime >= HeartbeatInterval then
            local heartbeat = createHeartbeat(scriptName, "coding", lineInfo)
            table.insert(HeartbeatQueue, heartbeat)
            LastTypingTime = os.time()
            LastActivityTime = os.time()
            persistQueue()
        end
    else
        -- Fallback
        addHeartbeat(scriptName)
    end
end)

-- Play Testing Detection
RunService.PreRender:Connect(function()
    if not TRACK_PLAY_TESTING then return end
    -- Check if we're in play test mode
    if RunService:IsRunMode() then
        if not isPlayTesting then
            isPlayTesting = true
            addHeartbeat("Play Testing", "debugging") -- Changed from "play_test" to "debugging"
        end
    else
        isPlayTesting = false
    end
end)

-- Track activity during play testing
RunService.Heartbeat:Connect(function()
    if isPlayTesting and os.time() - LastActivityTime >= HeartbeatInterval then
        if hasMouseMoved then
            addHeartbeat("Active Play Testing", "debugging")
            hasMouseMoved = false
        end
    end
end)

-- Error handling constants
local ERROR_CODES = {
    NO_API_KEY = "ERR_NO_API_KEY",
    NETWORK_ERROR = "ERR_NETWORK",
    AUTH_ERROR = "ERR_AUTH",
    RATE_LIMIT = "ERR_RATE_LIMIT",
    SERVER_ERROR = "ERR_SERVER",
    UNKNOWN = "ERR_UNKNOWN"
}

-- Add a variable to store the last error code
local LastErrorCode

-- Add near other global variables
local LastStatusMessage = ""
local HasSuccessfullyConnected = false  -- Add this new variable

--- Send Heartbeats ---
sendHeartbeats = function()
    if #HeartbeatQueue == 0 then
        return
    end

    if not WakaTimeAPIKey or WakaTimeAPIKey == "" then
        warn(ERROR_CODES.NO_API_KEY, "API key is not set. Cannot send heartbeats.")
        return
    end

    local jsonData = HttpService:JSONEncode(HeartbeatQueue)
    local headers = {
        ["Authorization"] = WakaTimeAPIKey:match("^Bearer ") and WakaTimeAPIKey or ("Bearer " .. WakaTimeAPIKey), -- Ensure Bearer prefix
        ["Content-Type"] = "application/json"
    }

    local success, response = pcall(function()
        return HttpService:RequestAsync({
            Url = APIEndpoint,
            Method = "POST",
            Headers = headers,
            Body = jsonData
        })
    end)

    if not success then
        LastStatusMessage = "Network error: " .. tostring(response)
        warn(ERROR_CODES.NETWORK_ERROR, LastStatusMessage)
        IsOffline = true
        LastErrorCode = ERROR_CODES.NETWORK_ERROR
        return
    end

    if response.Success then
        LastStatusMessage = "Successfully sent " .. #HeartbeatQueue .. " heartbeats"
        print(LastStatusMessage)
        HeartbeatQueue = {}
        persistQueue()
        IsOffline = false
        LastErrorCode = nil
        HasSuccessfullyConnected = true  -- Set to true on successful heartbeat
    else
        local errorCode = ERROR_CODES.UNKNOWN
        local statusCode = response.StatusCode
        local errorMessage = tostring(response.StatusMessage)

        if statusCode == 401 then
            errorCode = ERROR_CODES.AUTH_ERROR
            LastStatusMessage = "Authentication failed. Please check your API key"
        elseif statusCode == 429 then
            errorCode = ERROR_CODES.RATE_LIMIT
            LastStatusMessage = "Rate limit reached. Please wait"
        elseif statusCode >= 500 then
            errorCode = ERROR_CODES.SERVER_ERROR
            LastStatusMessage = "Server error: " .. errorMessage
        else
            LastStatusMessage = "Unknown error: " .. errorMessage
        end

        warn(errorCode, "Failed to send heartbeats. Status: " .. tostring(statusCode) ..
                " - " .. errorMessage)
        IsOffline = true
        LastErrorCode = errorCode

        -- Only persist queue for certain types of errors
        if errorCode ~= ERROR_CODES.AUTH_ERROR then
            persistQueue()
        else
            -- Clear queue if authentication failed
            HeartbeatQueue = {}
            persistQueue()
        end
    end
end

-- Add automatic heartbeat sending
spawn(function()
    while true do
        wait(HeartbeatInterval)
        if isPlayTesting and TRACK_PLAY_TESTING then
            addHeartbeat("Play Testing", "debugging") -- Changed from "play_test" to "debugging"
        end
        if os.time() - LastActivityTime <= IdleTimeout then
            sendHeartbeats()
        end
    end
end)

-- Add theme detection and colors
local Studio = settings().Studio

local ColorScheme = {
    Light = {
        Background = Color3.fromRGB(240, 240, 240),
        Text = Color3.fromRGB(0, 0, 0),
        ButtonBackground = Color3.fromRGB(220, 220, 220),
        ButtonText = Color3.fromRGB(0, 0, 0),
        WarningText = Color3.fromRGB(200, 0, 0),
        SuccessColor = Color3.fromRGB(0, 170, 0),
        ErrorColor = Color3.fromRGB(170, 0, 0),
        DialogBackground = Color3.fromRGB(250, 250, 250),
    },
    Dark = {
        Background = Color3.fromRGB(46, 46, 46),
        Text = Color3.fromRGB(255, 255, 255),
        ButtonBackground = Color3.fromRGB(60, 60, 60),
        ButtonText = Color3.fromRGB(255, 255, 255),
        WarningText = Color3.fromRGB(255, 80, 80),
        SuccessColor = Color3.fromRGB(80, 255, 80),
        ErrorColor = Color3.fromRGB(255, 80, 80),
        DialogBackground = Color3.fromRGB(40, 40, 40),
    }
}

local function getTheme()
    return Studio.Theme.Name:lower():match("dark") and "Dark" or "Light"
end

--- GUI Creation ---
local function createGUI()
    local theme = getTheme()
    local colors = ColorScheme[theme]

    local pluginGui = plugin:CreateDockWidgetPluginGui("WakaTimeSettings", DockWidgetPluginGuiInfo.new(
            Enum.InitialDockState.Float,
            false, -- Widget is initially disabled (changed from true)
            false, -- Widget's initial enabled state
            300,
            450,
            300,
            400
    ))

    pluginGui.Title = "WakaTime Settings"

    -- Main Frame
    local mainFrame = Instance.new("Frame")
    mainFrame.Size = UDim2.new(1, 0, 1, 0)
    mainFrame.BackgroundColor3 = colors.Background
    mainFrame.Parent = pluginGui

    local mainCorner = Instance.new("UICorner")
    mainCorner.CornerRadius = UDim.new(0.02, 0)
    mainCorner.Parent = mainFrame

    local buttonHeight = 0.06
    local spacing = 0.015
    local currentPosition = 0.02

    -- Warning Label at top
    local warningLabel = Instance.new("TextLabel")
    warningLabel.Size = UDim2.new(0.9, 0, buttonHeight * 0.8, 0)
    warningLabel.Position = UDim2.new(0.05, 0, currentPosition, 0)
    warningLabel.Text = "⚠️ Warning: These actions cannot be undone!"
    warningLabel.TextColor3 = colors.WarningText
    warningLabel.BackgroundTransparency = 1
    warningLabel.TextWrapped = true
    warningLabel.Parent = mainFrame
    currentPosition = currentPosition + buttonHeight * 0.8 + spacing

    -- Project Name Label (update to use global variable)
    projectLabel = Instance.new("TextLabel")  -- Remove local, use global
    projectLabel.Size = UDim2.new(0.9, 0, buttonHeight * 0.8, 0)
    projectLabel.Position = UDim2.new(0.05, 0, currentPosition, 0)
    projectLabel.Text = "Project: " .. CurrentProject
    projectLabel.TextColor3 = colors.Text
    projectLabel.BackgroundTransparency = 1
    projectLabel.TextXAlignment = Enum.TextXAlignment.Left
    projectLabel.TextWrapped = true
    projectLabel.Parent = mainFrame
    currentPosition = currentPosition + buttonHeight * 0.8 + spacing

    local function addCorners(button)
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0.2, 0)
        corner.Parent = button
    end

    -- Clear Queue Button
    local clearQueueButton = Instance.new("TextButton")
    clearQueueButton.Size = UDim2.new(0.44, 0, buttonHeight, 0)
    clearQueueButton.Position = UDim2.new(0.05, 0, currentPosition, 0)
    clearQueueButton.Text = "Clear Queue"
    clearQueueButton.BackgroundColor3 = Color3.fromRGB(200, 100, 100)
    clearQueueButton.TextColor3 = colors.ButtonText
    clearQueueButton.Parent = mainFrame
    addCorners(clearQueueButton)

    -- Force Send Queue Button
    local forceSendButton = Instance.new("TextButton")
    forceSendButton.Size = UDim2.new(0.44, 0, buttonHeight, 0)
    forceSendButton.Position = UDim2.new(0.51, 0, currentPosition, 0)
    forceSendButton.Text = "Force Send Queue"
    forceSendButton.BackgroundColor3 = Color3.fromRGB(100, 200, 100)
    forceSendButton.TextColor3 = colors.ButtonText
    forceSendButton.Parent = mainFrame
    addCorners(forceSendButton)
    currentPosition = currentPosition + buttonHeight + spacing * 2

    forceSendButton.MouseButton1Click:Connect(function()
        if #HeartbeatQueue > 0 then
            sendHeartbeats()
            LastStatusMessage = "Forcing queue send..."
        else
            LastStatusMessage = "Queue is empty"
        end
    end)

    clearQueueButton.MouseButton1Click:Connect(function()
        HeartbeatQueue = {}
        persistQueue()
        LastStatusMessage = "Queue cleared"
    end)

    -- Token Label
    local tokenLabel = Instance.new("TextLabel")
    tokenLabel.Size = UDim2.new(0.9, 0, buttonHeight * 0.8, 0)
    tokenLabel.Position = UDim2.new(0.05, 0, currentPosition, 0)
    tokenLabel.Text = "WakaTime API Key:"
    tokenLabel.TextColor3 = colors.Text
    tokenLabel.BackgroundTransparency = 1
    tokenLabel.TextXAlignment = Enum.TextXAlignment.Left
    tokenLabel.Parent = mainFrame
    currentPosition = currentPosition + buttonHeight * 0.8 + spacing

    local function processToken(text)
        local token = text

        -- Check for PowerShell format
        if text:match("%$env:BEARER_TOKEN") then
            token = text:match('%$env:BEARER_TOKEN="(.-)"')
        end

        -- Check for Bash format
        if text:match("export BEARER_TOKEN") then
            token = text:match('BEARER_TOKEN="(.-)"')
        end

        -- Add Bearer prefix if token exists and doesn't already have it
        if token and not token:match("^Bearer ") then
            token = "Bearer " .. token
        end

        return token
    end

    tokenInput = Instance.new("TextBox")
    tokenInput.Size = UDim2.new(0.9, 0, buttonHeight * 1.8, 0)
    tokenInput.Position = UDim2.new(0.05, 0, currentPosition, 0)
    tokenInput.Text = WakaTimeAPIKey
    tokenInput.BackgroundColor3 = colors.ButtonBackground
    tokenInput.TextColor3 = colors.Text
    tokenInput.PlaceholderText = "Enter API Key or paste install command..."
    tokenInput.TextWrapped = true
    tokenInput.ClearTextOnFocus = false
    tokenInput.Parent = mainFrame
    currentPosition = currentPosition + buttonHeight * 1.8 + spacing

    local tokenCorner = Instance.new("UICorner")
    tokenCorner.CornerRadius = UDim.new(0.1, 0)
    tokenCorner.Parent = tokenInput

    local saveTokenButton = Instance.new("TextButton")
    saveTokenButton.Size = UDim2.new(0.28, 0, buttonHeight, 0)
    saveTokenButton.Position = UDim2.new(0.05, 0, currentPosition, 0)
    saveTokenButton.Text = "Save Token"
    saveTokenButton.BackgroundColor3 = colors.ButtonBackground
    saveTokenButton.TextColor3 = colors.ButtonText
    saveTokenButton.Parent = mainFrame
    addCorners(saveTokenButton)

    saveTokenButton.MouseButton1Click:Connect(function()
        local inputText = tokenInput.Text
        local token = processToken(inputText)
        if token ~= inputText then
            print("Extracted token from command!")
        end
        tokenInput.Text = token
        saveAPIKey(token)
        print("Token saved successfully!")
    end)

    -- Settings Button
    local settingsButton = Instance.new("TextButton")
    settingsButton.Size = UDim2.new(0.28, 0, buttonHeight, 0)
    settingsButton.Position = UDim2.new(0.36, 0, currentPosition, 0)
    settingsButton.Text = "Settings"
    settingsButton.BackgroundColor3 = colors.ButtonBackground
    settingsButton.TextColor3 = colors.ButtonText
    settingsButton.Parent = mainFrame
    addCorners(settingsButton)

    -- API Key Help Button
    local apiHelpButton = Instance.new("TextButton")
    apiHelpButton.Size = UDim2.new(0.28, 0, buttonHeight, 0)
    apiHelpButton.Position = UDim2.new(0.67, 0, currentPosition, 0)
    apiHelpButton.Text = "Get API Key"
    apiHelpButton.BackgroundColor3 = colors.ButtonBackground
    apiHelpButton.TextColor3 = colors.ButtonText
    apiHelpButton.Parent = mainFrame
    addCorners(apiHelpButton)
    currentPosition = currentPosition + buttonHeight + spacing * 2

    -- Help and Submit buttons
    local helpButton = Instance.new("TextButton")
    helpButton.Size = UDim2.new(0.44, 0, buttonHeight, 0)
    helpButton.Position = UDim2.new(0.05, 0, currentPosition, 0)
    helpButton.Text = "Help"
    helpButton.BackgroundColor3 = colors.ButtonBackground
    helpButton.TextColor3 = colors.ButtonText
    helpButton.Parent = mainFrame
    addCorners(helpButton)

    local submitButton = Instance.new("TextButton")
    submitButton.Size = UDim2.new(0.44, 0, buttonHeight, 0)
    submitButton.Position = UDim2.new(0.51, 0, currentPosition, 0)
    submitButton.Text = "How to Submit"
    submitButton.BackgroundColor3 = colors.ButtonBackground
    submitButton.TextColor3 = colors.ButtonText
    submitButton.Parent = mainFrame
    addCorners(submitButton)
    currentPosition = currentPosition + buttonHeight + spacing

    -- Add Project ID section (new)
    local projectIdLabel = Instance.new("TextLabel")
    projectIdLabel.Size = UDim2.new(0.9, 0, buttonHeight * 0.8, 0)
    projectIdLabel.Position = UDim2.new(0.05, 0, currentPosition, 0)
    projectIdLabel.Text = "Override Project Name:"  -- Changed text
    projectIdLabel.TextColor3 = colors.Text
    projectIdLabel.BackgroundTransparency = 1
    projectIdLabel.TextXAlignment = Enum.TextXAlignment.Left
    projectIdLabel.Parent = mainFrame
    currentPosition = currentPosition + buttonHeight * 0.8 + spacing

    local projectIdInput = Instance.new("TextBox")
    projectIdInput.Size = UDim2.new(0.6, 0, buttonHeight, 0)
    projectIdInput.Position = UDim2.new(0.05, 0, currentPosition, 0)
    projectIdInput.PlaceholderText = "Enter project name..."  -- Changed placeholder
    projectIdInput.Text = ""
    projectIdInput.TextColor3 = colors.Text
    projectIdInput.BackgroundColor3 = colors.ButtonBackground
    projectIdInput.Parent = mainFrame
    addCorners(projectIdInput)

    local setProjectIdButton = Instance.new("TextButton")
    setProjectIdButton.Size = UDim2.new(0.25, 0, buttonHeight, 0)
    setProjectIdButton.Position = UDim2.new(0.7, 0, currentPosition, 0)
    setProjectIdButton.Text = "Set ID"
    setProjectIdButton.BackgroundColor3 = colors.ButtonBackground
    setProjectIdButton.TextColor3 = colors.ButtonText
    setProjectIdButton.Parent = mainFrame
    addCorners(setProjectIdButton)
    currentPosition = currentPosition + buttonHeight + spacing

    setProjectIdButton.MouseButton1Click:Connect(function()
        local newId = projectIdInput.Text
        if newId and newId ~= "" then
            local idValue = Instance.new("StringValue")
            idValue.Name = WAKATIME_ID_KEY
            idValue.Value = newId
            
            -- Try to store in ReplicatedStorage
            local success = pcall(function()
                -- Remove existing ID if any
                local existing = game:GetService("ReplicatedStorage"):FindFirstChild(WAKATIME_ID_KEY)
                if existing then existing:Destroy() end
                
                idValue.Parent = game:GetService("ReplicatedStorage")
                
                -- Add explanation comment
                local comment = Instance.new("Message")
                comment.Parent = idValue
                comment.Text = "This is a WakaTime project identifier. Please don't delete it - it helps track your coding time consistently."
            end)
            
            if success then
                -- Update current project name
                CurrentProject = "Project-" .. newId
                -- Update project label in main GUI
                if projectLabel then
                    projectLabel.Text = "Project: " .. CurrentProject
                end
                projectIdInput.Text = "ID Set Successfully!"
            else
                projectIdInput.Text = "Failed to set ID"
            end
        end
    end)

    -- Status label at bottom (moved down to account for new controls)
    local statusLabel = Instance.new("TextLabel")
    statusLabel.Size = UDim2.new(0.9, 0, buttonHeight, 0)
    statusLabel.Position = UDim2.new(0.05, 0, 0.95, 0)  -- Moved down slightly
    statusLabel.Text = "Status: Connected"
    statusLabel.TextColor3 = colors.SuccessColor
    statusLabel.BackgroundTransparency = 1
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.Parent = mainFrame

    -- Define updateStatus function
    local function updateStatus()
        if not WakaTimeAPIKey or WakaTimeAPIKey == "" then
            statusLabel.Text = "Status: No API Key Set - Set your API key to start tracking"
            statusLabel.TextColor3 = colors.WarningText
        elseif IsOffline then
            local errorText = LastStatusMessage ~= "" and (" - " .. LastStatusMessage) or ""
            statusLabel.Text = "Status: Offline" .. (LastErrorCode and " (" .. LastErrorCode .. ")" or "") .. errorText
            statusLabel.TextColor3 = colors.ErrorColor
        elseif not HasSuccessfullyConnected then
            statusLabel.Text = "Status: Waiting for first connection..."
            statusLabel.TextColor3 = colors.WarningText
        else
            local queueText = #HeartbeatQueue > 0 and (" - " .. #HeartbeatQueue .. " items in queue") or ""
            statusLabel.Text = "Status: Connected" .. (LastStatusMessage ~= "" and " - " .. LastStatusMessage or "") .. queueText
            statusLabel.TextColor3 = colors.SuccessColor
        end
    end

    local function showDialog(title, message)
        -- Destroy any existing dialogs first
        for _, child in pairs(mainFrame:GetChildren()) do
            if child.Name == "DialogWindow" then
                child:Destroy()
            end
        end

        local dialog = Instance.new("Frame")
        dialog.Name = "DialogWindow"
        dialog.Size = UDim2.new(0.8, 0, 0.6, 0)
        dialog.Position = UDim2.new(0.1, 0, 0.2, 0)
        dialog.BackgroundColor3 = colors.DialogBackground
        dialog.BorderSizePixel = 2
        dialog.ZIndex = 10
        dialog.Parent = mainFrame

        local dialogCorner = Instance.new("UICorner")
        dialogCorner.CornerRadius = UDim.new(0.05, 0)
        dialogCorner.Parent = dialog

        local titleLabel = Instance.new("TextLabel")
        titleLabel.Size = UDim2.new(1, 0, 0.1, 0)
        titleLabel.Text = title
        titleLabel.TextColor3 = colors.Text
        titleLabel.BackgroundTransparency = 1
        titleLabel.ZIndex = 10
        titleLabel.Parent = dialog

        local messageLabel = Instance.new("TextLabel")
        messageLabel.Size = UDim2.new(0.9, 0, 0.7, 0)
        messageLabel.Position = UDim2.new(0.05, 0, 0.15, 0)
        messageLabel.Text = message
        messageLabel.TextColor3 = colors.Text
        messageLabel.BackgroundTransparency = 1
        messageLabel.TextWrapped = true
        messageLabel.TextXAlignment = Enum.TextXAlignment.Left
        messageLabel.TextYAlignment = Enum.TextYAlignment.Top
        messageLabel.ZIndex = 10
        messageLabel.Parent = dialog

        local closeButton = Instance.new("TextButton")
        closeButton.Size = UDim2.new(0.3, 0, 0.1, 0)
        closeButton.Position = UDim2.new(0.35, 0, 0.85, 0)
        closeButton.Text = "Close"
        closeButton.BackgroundColor3 = colors.ButtonBackground
        closeButton.TextColor3 = colors.ButtonText
        closeButton.ZIndex = 10
        closeButton.Parent = dialog
        addCorners(closeButton)

        local closeCorner = Instance.new("UICorner")
        closeCorner.CornerRadius = UDim.new(0.2, 0)
        closeCorner.Parent = closeButton

        closeButton.MouseButton1Click:Connect(function()
            dialog:Destroy()
        end)
    end

    local function showSettingsDialog()
        -- Destroy any existing dialogs first
        for _, child in pairs(mainFrame:GetChildren()) do
            if child.Name == "DialogWindow" then
                child:Destroy()
            end
        end

        local dialog = Instance.new("Frame")
        dialog.Name = "DialogWindow"
        dialog.Size = UDim2.new(0.8, 0, 0.6, 0)
        dialog.Position = UDim2.new(0.1, 0, 0.2, 0)
        dialog.BackgroundColor3 = colors.DialogBackground
        dialog.BorderSizePixel = 2
        dialog.ZIndex = 10
        dialog.Parent = mainFrame

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, 0, 0.1, 0)
        title.Text = "Settings"
        title.TextColor3 = colors.Text
        title.BackgroundTransparency = 1
        title.Parent = dialog

        -- OS Selection
        local osLabel = Instance.new("TextLabel")
        osLabel.Size = UDim2.new(0.9, 0, 0.15, 0)
        osLabel.Position = UDim2.new(0.05, 0, 0.15, 0)
        osLabel.Text = "Override Operating System:\n(Use this if your OS is not detected correctly)"
        osLabel.TextColor3 = colors.Text
        osLabel.BackgroundTransparency = 1
        osLabel.TextXAlignment = Enum.TextXAlignment.Left
        osLabel.TextYAlignment = Enum.TextYAlignment.Top
        osLabel.TextWrapped = true
        osLabel.Parent = dialog

        local function createOSButton(text, pos)
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(0.28, 0, 0.12, 0)
            btn.Position = UDim2.new(0.05 + pos * 0.31, 0, 0.35, 0)
            btn.Text = text
            btn.BackgroundColor3 = OS_TYPE == text and Color3.fromRGB(100, 200, 100) or colors.ButtonBackground
            btn.TextColor3 = colors.ButtonText
            btn.Parent = dialog
            btn.ZIndex = 11
            addCorners(btn)

            btn.MouseButton1Click:Connect(function()
                OS_TYPE = text
                plugin:SetSetting("OverrideOS", text)
                dialog:Destroy()
            end)
            return btn
        end

        createOSButton("Windows", 0)
        createOSButton("Darwin", 1)
        createOSButton("Linux", 2)

        -- Add Project ID Override section
        local projectIdLabel = Instance.new("TextLabel")
        projectIdLabel.Size = UDim2.new(0.9, 0, 0.15, 0)
        projectIdLabel.Position = UDim2.new(0.05, 0, 0.5, 0)
        projectIdLabel.Text = "Project ID Override:\n(Warning: This will change how your project appears in WakaTime)"
        projectIdLabel.TextColor3 = colors.Text
        projectIdLabel.BackgroundTransparency = 1
        projectIdLabel.TextXAlignment = Enum.TextXAlignment.Left
        projectIdLabel.TextYAlignment = Enum.TextYAlignment.Top
        projectIdLabel.TextWrapped = true
        projectIdLabel.Parent = dialog

        local projectIdInput = Instance.new("TextBox")
        projectIdInput.Size = UDim2.new(0.6, 0, 0.12, 0)
        projectIdInput.Position = UDim2.new(0.05, 0, 0.65, 0)
        projectIdInput.PlaceholderText = "Enter new project ID..."
        projectIdInput.Text = ""
        projectIdInput.TextColor3 = colors.Text
        projectIdInput.BackgroundColor3 = colors.ButtonBackground
        projectIdInput.Parent = dialog
        addCorners(projectIdInput)

        local setProjectIdButton = Instance.new("TextButton")
        setProjectIdButton.Size = UDim2.new(0.25, 0, 0.12, 0)
        setProjectIdButton.Position = UDim2.new(0.7, 0, 0.65, 0)
        setProjectIdButton.Text = "Set ID"
        setProjectIdButton.BackgroundColor3 = colors.ButtonBackground
        setProjectIdButton.TextColor3 = colors.ButtonText
        setProjectIdButton.Parent = dialog
        addCorners(setProjectIdButton)

        setProjectIdButton.MouseButton1Click:Connect(function()
            local newId = projectIdInput.Text
            if newId and newId ~= "" then
                local idValue = Instance.new("StringValue")
                idValue.Name = WAKATIME_ID_KEY
                idValue.Value = newId
                
                -- Try to store in ReplicatedStorage first
                local success = pcall(function()
                    -- Remove existing ID if any
                    local existing = game:GetService("ReplicatedStorage"):FindFirstChild(WAKATIME_ID_KEY)
                    if existing then existing:Destroy() end
                    
                    idValue.Parent = game:GetService("ReplicatedStorage")
                    
                    -- Add explanation comment
                    local comment = Instance.new("Message")
                    comment.Parent = idValue
                    comment.Text = "This is a WakaTime project identifier. Please don't delete it - it helps track your coding time consistently."
                end)
                
                if success then
                    -- Update current project name
                    CurrentProject = "Project-" .. newId
                    -- Update project label in main GUI
                    if projectLabel then
                        projectLabel.Text = "Project: " .. CurrentProject
                    end
                    dialog:Destroy()
                else
                    projectIdInput.Text = "Failed to set ID"
                end
            end
        end)

        local closeButton = Instance.new("TextButton")
        closeButton.Size = UDim2.new(0.3, 0, 0.1, 0)
        closeButton.Position = UDim2.new(0.35, 0, 0.85, 0)
        closeButton.Text = "Close"
        closeButton.BackgroundColor3 = colors.ButtonBackground
        closeButton.TextColor3 = colors.ButtonText
        closeButton.Parent = dialog
        addCorners(closeButton)

        closeButton.MouseButton1Click:Connect(function()
            dialog:Destroy()
        end)
    end

    settingsButton.MouseButton1Click:Connect(showSettingsDialog)

    apiHelpButton.MouseButton1Click:Connect(function()
        showDialog("Get API Key",
                "How to get your WakaTime Token:\n\n" ..
                        "1. Go to highseas.hackclub.com\n" ..
                        "2. Copy the linux or windows or mac install command without edits into the Token field!\n" ..
                        "3. Press Save Token\n" ..
                        "Note: Your API key is secret, don't share it!"
        )
    end)

    helpButton.MouseButton1Click:Connect(function()
        showDialog("Need Help?",
                "If you're experiencing issues:\n\n" ..
                        "1. Open the Hack Club Slack\n" ..
                        "2. Go to #roblox-hackatime or #highseas-help channel\n" ..
                        "3. Describe your issue\n\n" ..
                        "The community will help you out!\n\n" ..
                        "Slack: hackclub.com/slack"
        )
    end)

    submitButton.MouseButton1Click:Connect(function()
        showDialog("Submit to High Seas",
                "How to Submit Your Project:\n\n" ..
                        "1. Create a GitHub repository for your project\n" ..
                        "2. Clone it using GitHub Desktop\n" ..
                        "3. Export your project:\n" ..
                        "   - Save place file (File -> Save to File)\n" ..
                        "   - Export all scripts (Right-click -> Save to File)\n" ..
                        "   - Put everything in your repo directory\n" ..
                        "   - Make a README.md in any editor u like!\n" ..
                        "4. Commit and push changes to GitHub\n" ..
                        "5. Go to highseas.hackclub.com\n" ..
                        "6. Submit your GitHub repo URL\n\n" ..
                        "Good luck, sailor! 🏴‍☠️"
        )
    end)

    spawn(function()
        while true do
            wait(5)
            updateStatus()
        end
    end)

    -- Add periodic refresh for project name
    spawn(function()
        while true do
            wait(60) -- Refresh every minute
            refreshProjectName()
        end
    end)

	return pluginGui
end

local guiInstance = createGUI() -- Create the GUI

settingsButton.Click:Connect(function()
    guiInstance.Enabled = not guiInstance.Enabled -- Toggle GUI visibility
end)

--- Initialize Plugin ---
loadQueue()
loadAPIKey()
print("Waka Init! Happy Hacking 🏴‍☠️")

-- Load play testing preference
spawn(function()
    TRACK_PLAY_TESTING = plugin:GetSetting("TrackPlayTesting")
    if TRACK_PLAY_TESTING == nil then
        TRACK_PLAY_TESTING = true
        plugin:SetSetting("TrackPlayTesting", true)
    end
end)

spawn(function()
    while true do
        wait(300)
        persistQueue()
    end
end)