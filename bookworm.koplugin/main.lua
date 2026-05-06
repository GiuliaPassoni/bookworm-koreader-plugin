--[[
    Bookworm: KOReader plugin to read multiple books at once.
    Shows the 3 most recently read, unfinished books on wake-up.
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local ImageWidget = require("ui/widget/imagewidget")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ReadHistory = require("readhistory")
local DocSettings = require("docsettings")
local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local GestureRange = require("ui/gesturerange")
local logger = require("logger")
local _ = require("gettext")

local MAX_BOOKS = 3
local PROGRESS_THRESHOLD = 0.99
local _state = {
    showing = false,
    last_resume = 0,
}

local BookInfoManager
pcall(function()
    BookInfoManager = require("plugins/coverbrowser.koplugin/bookinfomanager")
end)
if BookInfoManager then
    logger.info("Bookworm - BookInfoManager loaded OK")
else
    logger.info("Bookworm - BookInfoManager not available, covers disabled")
end

local Bookworm = WidgetContainer:extend{
    name = "Bookworm",
    is_doc_only = false,
    _showing = false,
}

function Bookworm:init()
    logger.info("Bookworm - init, instance:", tostring(self))
    self.ui.menu:registerToMainMenu(self)
    UIManager:scheduleIn(3.0, function()
        if _state.showing then return end
        ReadHistory:reload(true)
        if #ReadHistory.hist > 0 then
            _state.showing = true
            self:showSelector()
        end
    end)
end

function Bookworm:onResume()
    logger.info("Bookworm - onResume fire")
    local now = os.time()
    if (now - _state.last_resume) < 10 then
        logger.info("Bookworm - ignored, too soon:", now - _state.last_resume, "s")
        return
    end
    _state.last_resume = now
    _state.showing = false
    ReadHistory:reload(true)
    if #ReadHistory.hist > 0 then
        _state.showing = true
        self:showSelector()
        logger.info("Bookworm - showSelector called from onResume")
    end
end


-- function Bookworm:onDeviceResume() -- if infinite loop, use this one
--     logger.info("Bookworm - onDeviceResume fired")
--     if self._showing then return end
--     ReadHistory:reload(true)
--     if #ReadHistory.hist > 0 then
--         self._showing = true
--         self:showSelector()
--     end
-- end

function Bookworm:onWakeupFromSleep()
    logger.info("Bookworm - onWakeupFromSleep fired")
end

function Bookworm:onPowerPress()
    logger.info("Bookworm - onPowerPress fired")
end

function Bookworm:addToMainMenu(menu_items)
    menu_items.bookworm = {
        text = _("Bookworm - Read more books at once"),
        callback = function()
            ReadHistory:reload(true)
            if not _state.showing then
                _state.showing = true
                self:showSelector()
            end
        end,
    }
end

function Bookworm:getLatestBooks(card_w, card_h, badge_h)
    local valid_books = {}
    for _, item in ipairs(ReadHistory.hist) do
        if item and item.file then
            local progress = 0
            pcall(function()
                local doc_settings = DocSettings:open(item.file)
                progress = doc_settings:readSetting("percent_finished") or 0
            end)
            if progress < PROGRESS_THRESHOLD then
                local cover_bb = nil
                if BookInfoManager then
                    pcall(function()
                        local cover_specs = {
                            sizetag = "M",
                            max_cover_w = card_w - 4,
                            max_cover_h = card_h - badge_h - 4,
                        }
                        local bookinfo = BookInfoManager:getBookInfo(item.file, cover_specs)
                        if bookinfo and bookinfo.has_cover
                                and not bookinfo.ignore_cover
                                and bookinfo.cover_bb then
                            cover_bb = bookinfo.cover_bb
                        end
                    end)
                end
                table.insert(valid_books, {
                    text = item.text or item.file:match("([^/]+)$"),
                    path = item.file,
                    percent = math.floor(progress * 100),
                    cover_bb = cover_bb,
                })
            end
        end
        if #valid_books == MAX_BOOKS then break end
    end
    return valid_books
end

function Bookworm:closeDialog()
    if self.dialog then
        UIManager:close(self.dialog)
        self.dialog = nil
    end
    _state.showing = false
end

function Bookworm:makeCard(book, card_w, card_h)
    local b = book
    local self_ref = self
    local badge_h = 28
    local face_h = card_h - badge_h

    local face
    if b.cover_bb then
        local iw = b.cover_bb:getWidth()
        local ih = b.cover_bb:getHeight()
        local scale = math.min((card_w - 4) / iw, (face_h - 4) / ih)
        local img = ImageWidget:new{
            image = b.cover_bb,
            width = math.max(1, math.floor(iw * scale)),
            height = math.max(1, math.floor(ih * scale)),
        }
        img:_render()
        local img_size = img:getSize()
        face = FrameContainer:new{
            width = card_w,
            height = face_h,
            bordersize = 0,
            padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = card_w, h = face_h },
                FrameContainer:new{
                    width = img_size.w,
                    height = img_size.h,
                    bordersize = 0,
                    padding = 0,
                    img,
                },
            },
        }
    else
        face = FrameContainer:new{
            width = card_w,
            height = face_h,
            bordersize = 0,
            padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = card_w, h = face_h },
                TextBoxWidget:new{
                    text = b.text,
                    face = Font:getFace("cfont", 16),
                    width = card_w - 16,
                    height = face_h - 8,
                    alignment = "center",
                },
            },
        }
    end

    local badge = FrameContainer:new{
        width = card_w,
        height = badge_h,
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{
            dimen = Geom:new{ w = card_w, h = badge_h },
            TextWidget:new{
                text = b.percent .. "%",
                face = Font:getFace("cfont", 14),
            },
        },
    }

    local card_frame = FrameContainer:new{
        width = card_w,
        height = card_h,
        bordersize = 2,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            face,
            badge,
        },
    }

    local card = InputContainer:new{
        dimen = Geom:new{ w = card_w, h = card_h },
    }
    card.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = card.dimen } }
    }

    function card:onTap()
        self_ref:closeDialog()
        UIManager:scheduleIn(0.1, function()
            local ReaderUI = require("apps/reader/readerui")
            local FileManager = require("apps/filemanager/filemanager")
            if FileManager.instance then
                FileManager.instance:openFile(b.path)
            elseif ReaderUI.instance then
                ReaderUI.instance:switchDocument(b.path)
            else
                ReaderUI:showReader(b.path)
            end
        end)
        return true
    end

    card[1] = card_frame
    
    return card
end

function Bookworm:showSelector()
    logger.info("Bookworm - showSelector called")
    local books
    local Screen = Device.screen
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local gap = 14
    local dialog_w = math.floor(screen_w * 0.90)
    local title_h = 44
    local badge_h = 28
    local card_h = math.floor(screen_h * 0.40)

    -- card_w depends on number of books, but we need it for cover fetching.
    -- We pre-calculate using MAX_BOOKS; makeCard receives the real value.
    local card_w_max = math.floor((dialog_w - gap * (MAX_BOOKS + 1)) / MAX_BOOKS)

    books = self:getLatestBooks(card_w_max, card_h, badge_h)

    if #books == 0 then
        self._showing = false
        UIManager:show(InfoMessage:new{ text = _("No active books found.") })
        return
    end

    -- Recalculate card_w for actual number of books returned
    local card_w = math.floor((dialog_w - gap * (#books + 1)) / #books)

    local title_widget = FrameContainer:new{
        width = dialog_w,
        height = title_h,
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = dialog_w, h = title_h },
            TextWidget:new{
                text = _("Continue Reading"),
                face = Font:getFace("cfont", 20),
            },
        },
    }

    local hgroup = HorizontalGroup:new{ align = "top" }
    for _, book in ipairs(books) do
        hgroup[#hgroup + 1] = HorizontalSpan:new{ width = gap }
        hgroup[#hgroup + 1] = self:makeCard(book, card_w, card_h)
    end
    hgroup[#hgroup + 1] = HorizontalSpan:new{ width = gap }

    local cards_row = FrameContainer:new{
        width = dialog_w,
        height = card_h,
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        hgroup,
    }

    local inner = FrameContainer:new{
        width = dialog_w,
        height = title_h + gap + card_h + gap,
        bordersize = 2,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            title_widget,
            VerticalSpan:new{ width = gap },
            cards_row,
        },
    }

    local self_ref = self
    local overlay = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
    }
    overlay.ges_events = {
        TapOutside = { GestureRange:new{
            ges = "tap",
            range = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
        }},
    }
    function overlay:onTapOutside()
        self_ref:closeDialog()
        return true
    end
    overlay[1] = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        inner,
    }

    self.dialog = overlay
    UIManager:show(self.dialog)
end

return Bookworm
