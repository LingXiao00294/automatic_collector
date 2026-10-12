local Screen = require("widgets/screen")
local Text = require("widgets/text")
local TEMPLATES = require("widgets/redux/templates")
local API = require("ac_api")
local Features = require("ac_features")
local Controls = require("ac_controls")
local PAGE_SIZE = 3

local Panel = Class(Screen, function(self, owner, target, request, onclose)
    Screen._ctor(self, "AC_ControlPanel")
    self.owner, self.target = owner, target
    self.request, self.onclose = request, onclose
    self.page, self.pending, self.refresh_time, self.request_id = 1, {}, 0, 0
    self.state_revision, self.values = -1, {}
    self.black = self:AddChild(TEMPLATES.BackgroundTint())
    self.root = self:AddChild(TEMPLATES.ScreenRoot())
    self.dialog = self.root:AddChild(TEMPLATES.CurlyWindow(650, 460, "采集车控制面板"))
    self.dialog:SetScale(1)
    self.summary = self.dialog:AddChild(Text(CHATFONT, 24, "各项独立保存；拾取与运输持续工作。"))
    self.summary:SetPosition(0, 172)
    self.rows = {}
    for index = 1, PAGE_SIZE do
        local row = {}
        row.button = self.dialog:AddChild(TEMPLATES.StandardButton(function()
            self:ToggleFeature(row.name)
        end, "", { 500, 50 }))
        row.button:SetPosition(0, 108 - (index - 1) * 90)
        row.description = self.dialog:AddChild(Text(CHATFONT, 20, ""))
        row.description:SetPosition(0, 74 - (index - 1) * 90)
        row.description:SetRegionSize(590, 32)
        row.description:SetHAlign(ANCHOR_MIDDLE)
        self.rows[index] = row
    end
    self.previous = self.dialog:AddChild(TEMPLATES.StandardButton(function() self:ChangePage(-1) end,
        "上一页", { 140, 40 }))
    self.previous:SetPosition(-195, -153)
    self.next = self.dialog:AddChild(TEMPLATES.StandardButton(function() self:ChangePage(1) end,
        "下一页", { 140, 40 }))
    self.next:SetPosition(195, -153)
    self.page_text = self.dialog:AddChild(Text(CHATFONT, 22, ""))
    self.page_text:SetPosition(0, -153)
    self.close_button = self.dialog:AddChild(TEMPLATES.StandardButton(function() self:Close() end,
        "关闭", { 200, 45 }))
    self.close_button:SetPosition(0, -207)
    self.default_focus = self.close_button
    self:Refresh()
end)

function Panel:ChangePage(delta)
    local pages = math.max(1, math.ceil(#API.GetFeatureNames() / PAGE_SIZE))
    self.page = math.max(1, math.min(pages, self.page + delta))
    self:Refresh()
    self.close_button:SetFocus()
end

function Panel:ToggleFeature(name)
    if name == nil or not Features.IsAllowed(name, TUNING.AUTOMATIC_COLLECTOR) then return end
    local pending = self.pending[name]
    local current = Features.GetValue(self.values, name)
    -- Do not use and/or to select a pending false: it must stay false on a
    -- second click even before the server's first reply arrives.
    if pending ~= nil then current = pending.value end
    local value = not current
    self.request_id = self.request_id + 1
    self.pending[name] = { value = value, id = self.request_id, untiltime = GetStaticTime() + 3 }
    self.summary:SetString("各项独立保存；拾取与运输持续工作。")
    self:Refresh()
    self.request(self.target, name, value, self.request_id)
end

function Panel:ReadState(snapshot)
    local revision = Features.GetRevision(snapshot)
    if revision >= self.state_revision then
        self.state_revision = revision
        self.values = Features.Decode(snapshot)
    end
end

function Panel:ApplyResult(name, request_id, accepted, snapshot)
    if type(snapshot) == "string" and snapshot ~= "" then self:ReadState(snapshot) end
    local pending = self.pending[name]
    if pending ~= nil and pending.id == request_id then
        self.pending[name] = nil
        if not accepted then self.summary:SetString("设置未生效，已恢复当前开关。请重新打开面板。") end
    end
    self:Refresh()
end

function Panel:Refresh()
    self:ReadState(self.target._ac_features:value())
    local names = API.GetFeatureNames()
    local pages = math.max(1, math.ceil(#names / PAGE_SIZE))
    self.page = math.min(self.page, pages)
    local focus = {}
    for index, row in ipairs(self.rows) do
        local name = names[(self.page - 1) * PAGE_SIZE + index]
        row.name = name
        if name ~= nil then
            local definition = API.features[name]
            local value = Features.GetValue(self.values, name)
            local pending = self.pending[name]
            if pending ~= nil and GetStaticTime() >= pending.untiltime then
                self.pending[name], pending = nil, nil
                self.summary:SetString("未收到设置结果，已恢复当前开关。请重新打开面板。")
            end
            if pending ~= nil then value = pending.value end
            local allowed = Features.IsAllowed(name, TUNING.AUTOMATIC_COLLECTOR)
            local status = not allowed and "服务器已禁用" or value and "开启" or "关闭"
            row.button:SetText(definition.label .. "：" .. status)
            row.description:SetString(definition.description or "")
            row.button:Show()
            row.description:Show()
            if allowed then
                row.button:Enable()
                table.insert(focus, row.button)
            else
                row.button:Disable()
            end
        else
            row.button:Hide()
            row.description:Hide()
        end
    end
    self.previous:Hide()
    self.next:Hide()
    self.page_text:Hide()
    if pages > 1 then
        self.previous:Show()
        self.next:Show()
        self.page_text:Show()
        self.page_text:SetString(string.format("%d / %d", self.page, pages))
        if self.page > 1 then self.previous:Enable() table.insert(focus, self.previous)
        else self.previous:Disable() end
        if self.page < pages then self.next:Enable() table.insert(focus, self.next)
        else self.next:Disable() end
    end
    table.insert(focus, self.close_button)
    for index, button in ipairs(focus) do
        button:SetFocusChangeDir(MOVE_UP, focus[index == 1 and #focus or index - 1])
        button:SetFocusChangeDir(MOVE_DOWN, focus[index == #focus and 1 or index + 1])
    end
end

function Panel:OnUpdate(dt)
    if not Controls.CanUse(self.owner, self.target) then self:Close() return end
    self.refresh_time = self.refresh_time + dt
    if self.refresh_time >= .1 then
        self.refresh_time = 0
        self:Refresh()
    end
end

function Panel:OnControl(control, down)
    if Panel._base.OnControl(self, control, down) then return true end
    if not down and (control == CONTROL_CANCEL or control == CONTROL_PAUSE) then
        self:Close()
        return true
    end
end

function Panel:OnDestroy()
    if not self.closed then
        self.closed = true
        self.onclose(self)
    end
    Panel._base.OnDestroy(self)
end

function Panel:Close()
    if not self.closed then TheFrontEnd:PopScreen(self) end
end

return Panel
