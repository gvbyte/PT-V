#Requires -Version 5.1

class Settings {
    [hashtable]$Config

    Settings() {
        $this.LoadSettings()
    }

    [void]LoadSettings() {
        $settingsPath = Join-Path $PSScriptRoot "settings.json"
        if (Test-Path $settingsPath) {
            try {
                $jsonContent = Get-Content -Path $settingsPath -Raw
                $this.Config = ConvertFrom-Json $jsonContent -AsHashtable
            }
            catch {
                Write-Warning "Failed to load settings.json, using defaults: $($_.Exception.Message)"
                $this.LoadDefaults()
            }
        } else {
            $this.LoadDefaults()
        }
    }

    [void]LoadDefaults() {
        $this.Config = @{
            display = @{
                showFunctionNames = $true
                showDataTypes = $false
                expandFunctionDetails = $true
                showParameters = $true
                showVariables = $true
                maxContentLines = 50
            }
            navigation = @{
                enableFileOpening = $true
                defaultEditor = ""
                autoExpandFirstLevel = $false
                useVimKeys = $true
                allowNavigationToggle = $true
            }
            colors = @{
                fileColor = "Green"
                classColor = "Yellow"
                functionColor = "Magenta"
                parameterColor = "Cyan"
                variableColor = "White"
                selectedColor = "Cyan"
                errorColor = "Red"
            }
            parsing = @{
                includePrivateFunctions = $true
                includeComments = $false
                parseVariableAssignments = $true
                parseParameterTypes = $true
            }
        }
    }

    [object]Get([string]$path) {
        $keys = $path.Split('.')
        $current = $this.Config
        foreach ($key in $keys) {
            if ($current.ContainsKey($key)) {
                $current = $current[$key]
            } else {
                return $null
            }
        }
        return $current
    }
}

class FileItem {
    [string]$Name
    [string]$Path
    [string]$Type
    [bool]$IsExpanded
    [int]$Level
    [string[]]$Content
    [FileItem[]]$Children

    FileItem([string]$name, [string]$path, [string]$type, [int]$level) {
        $this.Name = $name
        $this.Path = $path
        $this.Type = $type
        $this.Level = $level
        $this.IsExpanded = $false
        $this.Content = @()
        $this.Children = @()
    }

    [void]Toggle() {
        $this.IsExpanded = -not $this.IsExpanded
    }
}

class CodeParser {
    static [FileItem[]]ParseJsonFile([string]$filePath) {
        $items = @()
        try {
            $jsonContent = Get-Content -Path $filePath -Raw -ErrorAction Stop
            $jsonObject = ConvertFrom-Json $jsonContent -ErrorAction Stop
            $items = [CodeParser]::ParseJsonObject($jsonObject, $filePath, 1)
        }
        catch {
            $errorItem = [FileItem]::new("Error parsing JSON: $($_.Exception.Message)", $filePath, "Error", 1)
            $items += $errorItem
        }
        return $items
    }

    static [FileItem[]]ParseJsonObject([object]$obj, [string]$filePath, [int]$level) {
        $items = @()

        if ($obj -is [PSCustomObject]) {
            $obj.PSObject.Properties | ForEach-Object {
                $property = $_
                $value = $property.Value

                if ($value -is [PSCustomObject] -or $value -is [Array]) {
                    $item = [FileItem]::new($property.Name, $filePath, "Object", $level)
                    if ($value -is [Array]) {
                        $item.Content = @("Array with $($value.Count) items")
                        for ($i = 0; $i -lt $value.Count; $i++) {
                            $arrayItem = [FileItem]::new("[$i]", $filePath, "ArrayItem", $level + 1)
                            if ($value[$i] -is [PSCustomObject] -or $value[$i] -is [Array]) {
                                $arrayItem.Children = [CodeParser]::ParseJsonObject($value[$i], $filePath, $level + 2)
                            } else {
                                $arrayItem.Content = @($value[$i].ToString())
                            }
                            $item.Children += $arrayItem
                        }
                    } else {
                        $item.Children = [CodeParser]::ParseJsonObject($value, $filePath, $level + 1)
                        $item.Content = @("Object with $($item.Children.Count) properties")
                    }
                    $items += $item
                } else {
                    $valueStr = if ($null -eq $value) { "null" } else { $value.ToString() }
                    $item = [FileItem]::new("$($property.Name): $valueStr", $filePath, "Property", $level)
                    $items += $item
                }
            }
        } elseif ($obj -is [Array]) {
            for ($i = 0; $i -lt $obj.Count; $i++) {
                $arrayItem = [FileItem]::new("[$i]", $filePath, "ArrayItem", $level)
                if ($obj[$i] -is [PSCustomObject] -or $obj[$i] -is [Array]) {
                    $arrayItem.Children = [CodeParser]::ParseJsonObject($obj[$i], $filePath, $level + 1)
                } else {
                    $valueStr = if ($null -eq $obj[$i]) { "null" } else { $obj[$i].ToString() }
                    $arrayItem.Content = @($valueStr)
                }
                $items += $arrayItem
            }
        }

        return $items
    }

    static [FileItem[]]ParsePowerShellFile([string]$filePath, [Settings]$settings) {
        $items = @()
        $content = Get-Content -Path $filePath -ErrorAction SilentlyContinue
        if (-not $content) { return $items }

        $currentClass = $null
        $currentFunction = $null
        $braceDepth = 0
        $inFunction = $false
        $inClass = $false

        for ($i = 0; $i -lt $content.Length; $i++) {
            $line = $content[$i].Trim()

            if ($line -match '^class\s+(\w+)') {
                $className = $matches[1]
                $currentClass = [FileItem]::new($className, $filePath, "Class", 1)
                $currentClass.Content = @($content[$i])
                $items += $currentClass
                $inClass = $true
                $braceDepth = 0
            }
            elseif ($line -match '^\s*function\s+(\w+)' -or ($inClass -and $line -match '^\s*\[([^\]]+)\]\s*(\w+)\s*\(') -or ($inClass -and $line -match '^\s*(\w+)\s*\(.*\)\s*\{?\s*$')) {
                $functionName = ""
                $returnType = ""
                $isValidFunction = $false

                if ($line -match '^\s*function\s+(\w+)') {
                    $functionName = $matches[1]
                    $isValidFunction = $true
                }
                elseif ($inClass -and $line -match '^\s*\[([^\]]+)\]\s*(\w+)\s*\(') {
                    $returnType = $matches[1]
                    $functionName = $matches[2]
                    $controlStructures = @('if', 'elseif', 'else', 'while', 'for', 'foreach', 'do', 'switch', 'try', 'catch', 'finally')
                    if ($functionName -notin $controlStructures -and $functionName.Length -gt 0) {
                        $isValidFunction = $true
                    }
                }
                elseif ($inClass -and $line -match '^\s*(\w+)\s*\(.*\)\s*\{?\s*$') {
                    $functionName = $matches[1]
                    $controlStructures = @('if', 'elseif', 'else', 'while', 'for', 'foreach', 'do', 'switch', 'try', 'catch', 'finally')
                    if ($functionName -notin $controlStructures -and $functionName.Length -gt 0 -and $functionName -match '^[A-Za-z]\w*$') {
                        $isValidFunction = $true
                    }
                }

                if ($isValidFunction -and $functionName) {
                    $level = if ($currentClass) { 2 } else { 1 }
                    $displayName = if ($returnType) { "[$returnType] $functionName" } else { $functionName }
                    $currentFunction = [FileItem]::new($displayName, $filePath, "Function", $level)

                    $functionContent = @()
                    $functionContent += $content[$i]

                    $j = $i + 1
                    $funcBraceDepth = 0
                    $foundOpenBrace = $false
                    $parameters = @()
                    $variables = @()

                    while ($j -lt $content.Length) {
                        $funcLine = $content[$j]
                        $functionContent += $funcLine

                        if ($settings.Get('parsing.parseParameterTypes')) {
                            if ($funcLine -match 'param\s*\(') {
                                $k = $j + 1
                                $paramDepth = 1
                                while ($k -lt $content.Length -and $paramDepth -gt 0) {
                                    $paramLine = $content[$k]
                                    if ($paramLine -match '\(') { $paramDepth++ }
                                    if ($paramLine -match '\)') { $paramDepth-- }

                                    if ($paramLine -match '\[([^\]]+)\]\s*\$([^,\)\s=]+)') {
                                        $paramType = $matches[1]
                                        $paramName = $matches[2]
                                        $paramItem = [FileItem]::new("$paramName : $paramType", $filePath, "Parameter", $level + 2)
                                        $parameters += $paramItem
                                    }
                                    elseif ($paramLine -match '\$([^,\)\s=]+)') {
                                        $paramName = $matches[1]
                                        $paramItem = [FileItem]::new($paramName, $filePath, "Parameter", $level + 2)
                                        $parameters += $paramItem
                                    }
                                    $k++
                                }
                            }
                            elseif ($j -eq $i + 1 -and $content[$i] -match '\(([^\)]*)\)') {
                                $paramString = $matches[1]
                                $paramParts = $paramString -split ','
                                foreach ($part in $paramParts) {
                                    $part = $part.Trim()
                                    if ($part -match '\[([^\]]+)\]\s*\$([^\s=]+)') {
                                        $paramType = $matches[1]
                                        $paramName = $matches[2]
                                        $paramItem = [FileItem]::new("$paramName : $paramType", $filePath, "Parameter", $level + 2)
                                        $parameters += $paramItem
                                    }
                                    elseif ($part -match '\$([^\s=]+)') {
                                        $paramName = $matches[1]
                                        $paramItem = [FileItem]::new($paramName, $filePath, "Parameter", $level + 2)
                                        $parameters += $paramItem
                                    }
                                }
                            }
                        }

                        if ($settings.Get('parsing.parseVariableAssignments') -and $funcLine -match '\$([^\s=]+)\s*=') {
                            $varName = $matches[1]
                            $paramNames = @()
                            foreach ($param in $parameters) {
                                $paramNames += ($param.Name -replace ' : .*', '')
                            }
                            $existingVarNames = $variables | ForEach-Object { $_.Name }
                            if ($varName -notin $paramNames -and $varName -notin $existingVarNames) {
                                $varItem = [FileItem]::new($varName, $filePath, "Variable", $level + 2)
                                $variables += $varItem
                            }
                        }

                        if ($funcLine -match '\{') {
                            $foundOpenBrace = $true
                            $funcBraceDepth++
                        }
                        if ($funcLine -match '\}') {
                            $funcBraceDepth--
                            if ($foundOpenBrace -and $funcBraceDepth -eq 0) {
                                break
                            }
                        }
                        $j++
                    }

                    if ($settings.Get('display.expandFunctionDetails')) {
                        if ($settings.Get('display.showParameters') -and $parameters.Count -gt 0) {
                            $paramContainer = [FileItem]::new("Parameters ($($parameters.Count))", $filePath, "Container", $level + 1)
                            $paramContainer.Children = $parameters
                            $currentFunction.Children += $paramContainer
                        }
                        if ($settings.Get('display.showVariables') -and $variables.Count -gt 0) {
                            $uniqueVars = $variables | Sort-Object Name | Group-Object Name | ForEach-Object { $_.Group[0] }
                            $varContainer = [FileItem]::new("Variables ($($uniqueVars.Count))", $filePath, "Container", $level + 1)
                            $varContainer.Children = $uniqueVars
                            $currentFunction.Children += $varContainer
                        }
                    }

                    if (-not $settings.Get('display.showFunctionNames')) {
                        $currentFunction.Content = $functionContent
                    }

                    if ($currentClass) {
                        $currentClass.Children += $currentFunction
                    } else {
                        $items += $currentFunction
                    }
                }
            }

            if ($line -match '\{') { $braceDepth++ }
            if ($line -match '\}') {
                $braceDepth--
                if ($braceDepth -eq 0 -and $inClass) {
                    $inClass = $false
                    $currentClass = $null
                }
            }
        }

        return $items
    }
}

class FileScanner {
    [FileItem[]]$Files
    [Settings]$Settings

    FileScanner([Settings]$settings) {
        $this.Files = @()
        $this.Settings = $settings
    }

    [void]ScanCurrentDirectory() {
        $this.Files = @()
        $fileList = Get-ChildItem -Path "." -File -Recurse | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1', '.cs', '.js', '.ts', '.py', '.cpp', '.h', '.java', '.json') }

        foreach ($file in $fileList) {
            $fileItem = [FileItem]::new($file.Name, $file.FullName, "File", 0)

            if ($file.Extension -in @('.ps1', '.psm1')) {
                $fileItem.Children = [CodeParser]::ParsePowerShellFile($file.FullName, $this.Settings)
            }
            elseif ($file.Extension -eq '.json') {
                $fileItem.Children = [CodeParser]::ParseJsonFile($file.FullName)
            }

            $this.Files += $fileItem
        }
    }
}

class ViewerUI {
    [int]$CurrentIndex
    [FileItem[]]$DisplayItems
    [int]$ScrollOffset
    [int]$MaxDisplayLines
    [Settings]$Settings
    [bool]$UseVimKeys

    ViewerUI([Settings]$settings) {
        $this.CurrentIndex = 0
        $this.DisplayItems = @()
        $this.ScrollOffset = 0
        $this.MaxDisplayLines = [Console]::WindowHeight - 3
        $this.Settings = $settings
        $this.UseVimKeys = $settings.Get('navigation.useVimKeys')
    }

    [void]BuildDisplayList([FileItem[]]$files) {
        $this.DisplayItems = @()
        foreach ($file in $files) {
            $this.AddItemRecursively($file)
        }
    }

    [void]AddItemRecursively([FileItem]$item) {
        $this.DisplayItems += $item
        if ($item.IsExpanded -and $item.Children.Count -gt 0) {
            foreach ($child in $item.Children) {
                $this.AddItemRecursively($child)
            }
        }
    }

    [void]Render() {
        Clear-Host

        $navMode = if ($this.UseVimKeys) { "VIM" } else { "Arrow" }
        Write-Host "PowerShell Code Viewer - $navMode Navigation Mode - q: quit, v: toggle nav" -ForegroundColor Yellow
        if ($this.UseVimKeys) {
            Write-Host "h: collapse, l: expand, j: down, k: up, Enter: open file, v: switch to arrows" -ForegroundColor Gray
        } else {
            Write-Host "Left: collapse, Right: expand, Down: down, Up: up, Enter: open file, v: switch to vim" -ForegroundColor Gray
        }
        Write-Host ("-" * 60) -ForegroundColor DarkGray

        $startIndex = $this.ScrollOffset
        $endIndex = [Math]::Min($startIndex + $this.MaxDisplayLines, $this.DisplayItems.Count)

        for ($i = $startIndex; $i -lt $endIndex; $i++) {
            $item = $this.DisplayItems[$i]
            $prefix = ""
            $color = "White"

            if ($i -eq $this.CurrentIndex) {
                $prefix = "> "
                $color = "Cyan"
            } else {
                $prefix = "  "
            }

            $indent = "  " * $item.Level

            switch ($item.Type) {
                "File" {
                    $fileColor = $this.Settings.Get('colors.fileColor')
                    $color = if ($i -eq $this.CurrentIndex) { $this.Settings.Get('colors.selectedColor') } else { $fileColor }
                    $expandChar = if ($item.Children.Count -gt 0) { if ($item.IsExpanded) { "[-] " } else { "[+] " } } else { "    " }
                    Write-Host "$prefix$indent$expandChar$($item.Name)" -ForegroundColor $color
                }
                "Class" {
                    $classColor = $this.Settings.Get('colors.classColor')
                    $color = if ($i -eq $this.CurrentIndex) { $this.Settings.Get('colors.selectedColor') } else { $classColor }
                    $expandChar = if ($item.Children.Count -gt 0) { if ($item.IsExpanded) { "[-] " } else { "[+] " } } else { "    " }
                    Write-Host "$prefix$indent$expandChar$($item.Name)" -ForegroundColor $color
                }
                "Function" {
                    $functionColor = $this.Settings.Get('colors.functionColor')
                    $color = if ($i -eq $this.CurrentIndex) { $this.Settings.Get('colors.selectedColor') } else { $functionColor }
                    $hasContent = $item.Content.Count -gt 1 -or $item.Children.Count -gt 0
                    $expandChar = if ($hasContent) { if ($item.IsExpanded) { "[-] " } else { "[+] " } } else { "    " }
                    Write-Host "$prefix$indent$expandChar$($item.Name)" -ForegroundColor $color

                    if ($item.IsExpanded -and $item.Content.Count -gt 0 -and -not $this.Settings.Get('display.showFunctionNames')) {
                        $maxLines = $this.Settings.Get('display.maxContentLines')
                        $lineCount = 0
                        foreach ($line in $item.Content) {
                            if ($lineCount -ge $maxLines) { break }
                            $i++
                            if ($i -ge $endIndex) { break }
                            Write-Host "    $indent    $line" -ForegroundColor DarkGray
                            $lineCount++
                        }
                        $i--
                    }
                }
                "Container" {
                    $color = if ($i -eq $this.CurrentIndex) { $this.Settings.Get('colors.selectedColor') } else { "DarkCyan" }
                    $expandChar = if ($item.Children.Count -gt 0) { if ($item.IsExpanded) { "[-] " } else { "[+] " } } else { "    " }
                    Write-Host "$prefix$indent$expandChar$($item.Name)" -ForegroundColor $color
                }
                "Parameter" {
                    $paramColor = $this.Settings.Get('colors.parameterColor')
                    $color = if ($i -eq $this.CurrentIndex) { $this.Settings.Get('colors.selectedColor') } else { $paramColor }
                    Write-Host "$prefix$indent    $($item.Name)" -ForegroundColor $color
                }
                "Variable" {
                    $varColor = $this.Settings.Get('colors.variableColor')
                    $color = if ($i -eq $this.CurrentIndex) { $this.Settings.Get('colors.selectedColor') } else { $varColor }
                    Write-Host "$prefix$indent    $($item.Name)" -ForegroundColor $color
                }
                "Object" {
                    $color = if ($i -eq $this.CurrentIndex) { "Cyan" } else { "Blue" }
                    $expandChar = if ($item.Children.Count -gt 0) { if ($item.IsExpanded) { "[-] " } else { "[+] " } } else { "    " }
                    Write-Host "$prefix$indent$expandChar$($item.Name)" -ForegroundColor $color
                    if ($item.IsExpanded -and $item.Content.Count -gt 0) {
                        foreach ($line in $item.Content) {
                            $i++
                            if ($i -ge $endIndex) { break }
                            Write-Host "    $indent    $line" -ForegroundColor DarkGray
                        }
                        $i--
                    }
                }
                "ArrayItem" {
                    $color = if ($i -eq $this.CurrentIndex) { "Cyan" } else { "DarkBlue" }
                    $expandChar = if ($item.Children.Count -gt 0) { if ($item.IsExpanded) { "[-] " } else { "[+] " } } else { "    " }
                    Write-Host "$prefix$indent$expandChar$($item.Name)" -ForegroundColor $color
                    if ($item.IsExpanded -and $item.Content.Count -gt 0) {
                        foreach ($line in $item.Content) {
                            $i++
                            if ($i -ge $endIndex) { break }
                            Write-Host "    $indent    $line" -ForegroundColor DarkGray
                        }
                        $i--
                    }
                }
                "Property" {
                    $color = if ($i -eq $this.CurrentIndex) { "Cyan" } else { "White" }
                    Write-Host "$prefix$indent    $($item.Name)" -ForegroundColor $color
                }
                "Error" {
                    $color = if ($i -eq $this.CurrentIndex) { "Cyan" } else { "Red" }
                    Write-Host "$prefix$indent    $($item.Name)" -ForegroundColor $color
                }
            }
        }

        Write-Host ("-" * 60) -ForegroundColor DarkGray
        Write-Host "Item $($this.CurrentIndex + 1) of $($this.DisplayItems.Count)" -ForegroundColor Gray
    }

    [void]MoveUp() {
        if ($this.CurrentIndex -gt 0) {
            $this.CurrentIndex--
            if ($this.CurrentIndex -lt $this.ScrollOffset) {
                $this.ScrollOffset = $this.CurrentIndex
            }
        }
    }

    [void]MoveDown() {
        if ($this.CurrentIndex -lt $this.DisplayItems.Count - 1) {
            $this.CurrentIndex++
            if ($this.CurrentIndex -ge $this.ScrollOffset + $this.MaxDisplayLines) {
                $this.ScrollOffset = $this.CurrentIndex - $this.MaxDisplayLines + 1
            }
        }
    }

    [void]Expand() {
        if ($this.DisplayItems.Count -gt 0 -and $this.CurrentIndex -lt $this.DisplayItems.Count) {
            $currentItem = $this.DisplayItems[$this.CurrentIndex]
            if ($currentItem.Children.Count -gt 0 -or $currentItem.Content.Count -gt 1) {
                $currentItem.IsExpanded = $true
            }
        }
    }

    [void]Collapse() {
        if ($this.DisplayItems.Count -gt 0 -and $this.CurrentIndex -lt $this.DisplayItems.Count) {
            $currentItem = $this.DisplayItems[$this.CurrentIndex]
            $currentItem.IsExpanded = $false
        }
    }

    [void]OpenFile() {
        if ($this.DisplayItems.Count -gt 0 -and $this.CurrentIndex -lt $this.DisplayItems.Count) {
            $currentItem = $this.DisplayItems[$this.CurrentIndex]
            if ($currentItem.Type -eq "File" -and $this.Settings.Get('navigation.enableFileOpening')) {
                $editor = $this.Settings.Get('navigation.defaultEditor')
                if ($editor -and $editor -ne "") {
                    Start-Process $editor $currentItem.Path
                } else {
                    Invoke-Item $currentItem.Path
                }
            }
        }
    }

    [void]ToggleNavigationMode() {
        if ($this.Settings.Get('navigation.allowNavigationToggle')) {
            $this.UseVimKeys = -not $this.UseVimKeys
            $this.Settings.Config.navigation.useVimKeys = $this.UseVimKeys
        }
    }
}

class PowerShellViewer {
    [FileScanner]$Scanner
    [ViewerUI]$UI
    [Settings]$Settings

    PowerShellViewer() {
        $this.Settings = [Settings]::new()
        $this.Scanner = [FileScanner]::new($this.Settings)
        $this.UI = [ViewerUI]::new($this.Settings)
    }

    [void]Run() {
        Write-Host "Scanning files..." -ForegroundColor Yellow
        $this.Scanner.ScanCurrentDirectory()

        if ($this.Scanner.Files.Count -eq 0) {
            Write-Host "No supported files found in current directory." -ForegroundColor Red
            return
        }

        do {
            $this.UI.BuildDisplayList($this.Scanner.Files)
            $this.UI.Render()

            $key = [Console]::ReadKey($true)

            if ($this.UI.UseVimKeys) {
                switch ($key.Key) {
                    'J' { $this.UI.MoveDown() }
                    'K' { $this.UI.MoveUp() }
                    'L' { $this.UI.Expand() }
                    'H' { $this.UI.Collapse() }
                    'Enter' { $this.UI.OpenFile() }
                    'V' { $this.UI.ToggleNavigationMode() }
                    'Q' { return }
                }
            } else {
                switch ($key.Key) {
                    'DownArrow' { $this.UI.MoveDown() }
                    'UpArrow' { $this.UI.MoveUp() }
                    'RightArrow' { $this.UI.Expand() }
                    'LeftArrow' { $this.UI.Collapse() }
                    'Enter' { $this.UI.OpenFile() }
                    'V' { $this.UI.ToggleNavigationMode() }
                    'Q' { return }
                }
            }
        } while ($true)
    }
}

$viewer = [PowerShellViewer]::new()
$viewer.Run()