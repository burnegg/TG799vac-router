<%
-- Enable localization
gettext.textdomain('webui-core')

local format = string.format
local table = table
local ui_helper = require("web.ui_helper")
local content_helper = require("web.content_helper")
local post_helper = require("web.post_helper")
-- local tprint = require("tch.tableprint")

local content_parental = {
  state = "uci.parental.general.enable",
  exclude = "uci.parental.general.exclude",
}
content_helper.getExactContent(content_parental)

local uci_parental_path = "uci.parental.URLfilter."
local parental_columns = {
    {
        header = T"Site",
        name = "site",
        param = "site",
        type = "text",
        attr = { input = { class="span2" } },
    },
    {
        header = T"Device",
        name = "device",
        param = "device",
        type = "text",
        attr = { input = { class="span2"} },
    },
}

local parental_options = {
    tableid         = "urlfilter",
    basepath        = uci_parental_path,
}

-- get an initial read from UCI
local parental_data = post_helper.handleTableQuery(parental_columns, parental_options)
local rulecount = 0

-- Parental Control data
function updataParentalTableData ()
    local data = parental_data
    local urlCount = 0
    local id = 0

    -- just looking for a count of entries to return for now
    for id, val in ipairs (data) do
	    urlCount = id
    end
    return data, urlCount
end

parental_data, rulecount = updataParentalTableData()

local session = ngx.ctx.session
local blockenabled = true
local switchtext
local n_block_rules

if session:hasAccess("/modals/parental-modal.lp") then
    if (content_parental["state"] == '1') then
      switchtext = T"Site blocking enabled"
      blockenabled = true
    else
      switchtext = T"Site blocking disabled"
      blockenabled = false
    end

    n_block_rules = tonumber(rulecount)
%>

<div class="span3">
  <div class="smallcard">

    <%= ui_helper.createCardHeaderNoIcon(T"Parental Controls", "modals/parental-modal.lp") %>

    <div class="content">
    <% ngx.print(
            ui_helper.createSimpleLight(blockenabled, switchtext),
            '<p></p>',
            '<p class="subinfos">',
            format( N("<strong %s>%d site blocking</strong> rule is defined",
                      "<strong %s>%d site blocking</strong> rules are defined", n_redir_rules),
                      'class="modal-link" data-toggle="modal" data-remote="modals/parental-modal.lp" data-id="parental-modal"', n_block_rules),
            '</p>'
            )

    %>
    </div>
  </div>
</div>
<%
end
%>
