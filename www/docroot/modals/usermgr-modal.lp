<%
-- Localization
gettext.textdomain('webui-core')

local proxy = require("datamodel")
local content_helper = require("web.content_helper")
local ui_helper = require("web.ui_helper")
local message_helper = require("web.uimessage_helper")
local post_helper = require("web.post_helper")
local taint_mt = require("web.taint").taint_mt
local bridged = require("bridgedmode_helper")
local type, setmetatable, random = type, setmetatable, math.random
local table, ipairs, istainted, format = table, ipairs, string.istainted, string.format

-- Shortcuts to validation helpers to make lines shorter
local gVIES = post_helper.getValidateInEnumSelect
local vNES = post_helper.validateNonEmptyString

local function gVEL(len)
    return function(value, object, key)
        if type(value) ~= "string" and not istainted(value) then
            return nil, "Received a non string value"
        end
        if #value ~= len then
            return nil, format("String must be exactly %d characters long", len)
        end
        return true
    end
end

local roleslist = {
    { "guest", T"Guest"},
    { "admin", T"Admin"},
}

local umgr_columns = {
    {
        header = T"Name",
        name = "name",
        param = "name",
        type = "text",
        attr = { input = { class="span2" } },
    },
    {
        header = T"Role",
        name = "role",
        param = "role",
        default = "guest",
        type = "select",
        values = roleslist,
        attr = { select = { class="span2" } },
    },
    {
        header = "",
        legend = T"Change password",
        name = "passwordmgt",
        param = "passwordmgt",
        type = "aggregate",
        synthesis = nil,
        subcolumns = {
            {
                header = T"Password",
                name = "password",
                param = "password",
                type = "password",
                attr = { input = { class="span2" }},
            },
            {
                header = T"Repeat Password",
                name = "password2",
                param = "password2",
                type = "password",
                attr = { input = { class="span2" }},
            },
            {
                header = T"SRP salt",
                name = "srp_salt",
                param = "srp_salt",
                type = "hidden",
                attr = { },
            },
            {
                header = T"SRP verifier",
                name = "srp_verifier",
                param = "srp_verifier",
                type = "hidden",
                attr = { },
            },

        },
    }
}

local umgr_attributes = {
}

local wu = {}
local users
local currentuser = ngx.ctx.session:getusername()

local umgr_filter = function(data)
    if not users then -- we need to initialize it after the current table operation happened so do this on the first run of umgr_filter
        -- this is because filter is called in loadTableData which happens after committing the current operation
        users = setmetatable({}, taint_mt)
        content_helper.addListContent(wu, { users = "uci.web.sessionmgr.@default.users." })
        for _,v in ipairs(wu.users) do
            users[v] = true
        end
    end
    local name = data.paramindex -- name of the entry
    local username = data.name

    -- check either it's an already existing entry
    if name and users[name] then
        if name == "usr_guest" then
            return true
        elseif name == "usr_admin" or currentuser == username then
            return {
                canEdit = true,
                canDelete = false
            }
        else
            return true
        end
    else
        return nil
    end
end

local umgr_defaultObject = nil

-- when creating a new user, name the entry with a random name otherwise won't be able to retrieve the name of the entry
-- after calling proxy.add
local function generateNewObjectname()
    return "usr_default_" .. tostring(random()):sub(3)
end

local umgr_options = {
    tableid = "usermgr",
    basepath = "uci.web.user.@.",
    createMsg = "Add new user",
    addNamedObject = true,
    sorted = "name",
    objectName = generateNewObjectname(),
}

local function userStateModified(object)
    local post_args = ngx.req.get_post_args()
    local action = string.format("%s", post_args.action)
    if action == "TABLE-MODIFY" then
        local basepath = "uci.web.user.@" .. umgr_options.changesessionindex .. "."
        local userData = {
            name = basepath .. "name",
            srp_salt = basepath .. "srp_salt",
        }
        content_helper.getExactContent(userData)
        return true, userData.name ~= object.name, userData.srp_salt ~= object.srp_salt
    end
    return false
end

local function clearPassword(value, object, key)
    local state, bname, bsalt = userStateModified(object)
    if state and bname then
        if not bsalt then
            return nil, T"Please set the new password for new user."
        end
    end

    object[key] = nil
    return true
end

local umgr_valid = {
    name = vNES,
    role = gVIES(roleslist),
    srp_salt = gVEL(8),
    srp_verifier = gVEL(512),
    password = clearPassword,
    password2 = clearPassword,
}

local function onAdd(index, content)
    local result, msg = ngx.ctx.session:addUserToManager(index)
    umgr_options.errmsg = msg
end

local function onDelete(index)
    local result, msg = ngx.ctx.session:delUserFromManager(index)
    umgr_options.errmsg = msg
end

local function onModify(index, content)
    local result, msg = ngx.ctx.session:reloadAllUsers()
    umgr_options.errmsg = msg
    local defaultuser = proxy.get("uci.web.uiconfig.@uidefault.defaultuser")[1].value
    if defaultuser ~= "" and not msg and content.name == defaultuser then
        ngx.ctx.session:toggleDefaultUser(false)
        proxy.set("uci.web.uiconfig.@uidefault.defaultuser", "")
    end
end

umgr_options.onAdd = onAdd
umgr_options.onModify = onModify
umgr_options.onDelete = onDelete

--if the user is admin and legacy_salt is not null, reset the legacy_salt to null
if ngx.req.get_method() == "POST" then
     local legacy_salt = proxy.get("uci.web.user.@usr_admin.legacy_salt")[1].value

     --If the role:admin modified the password(srp_salt changed), legacy_salt is not null, reset it.
     if legacy_salt and ("" ~= legacy_salt) and (ngx.req.get_post_args().action == "TABLE-MODIFY") then
         local adminname = proxy.get("uci.web.user.@usr_admin.name")[1].value
         local pri_srpsalt = proxy.get("uci.web.user.@usr_admin.srp_salt")[1].value
         -- tprint(pri_srpsalt)

         if (pri_srpsalt ~= ngx.req.get_post_args().srp_salt) and (ngx.ctx.session:getrole() == "admin")
             and (ngx.ctx.session:getusername() == adminname) then
                 proxy.set("uci.web.user.@usr_admin.legacy_salt", "")
                 proxy.apply()
                 --ngx.log(ngx.ERR, "succussfully reset the legacy_salt to null")
         end
     end
end

local umgr_data, umgr_helpmsg = post_helper.handleTableQuery(umgr_columns, umgr_options, umgr_filter, umgr_defaultObject, umgr_valid)

local uri = ngx.var.uri
local help_link = { href="/help/index.html?anchor=" .. uri:match("/([^/]+)%.lp") }
%>

<% =ui_helper.createHeader(T"Management", false, false, nil, help_link) %>

<div class="modal-body update">
<%
if not bridged.isBridgedMode() then
    local tabs = {
    {
        desc = T"User Manager",
        active = "active",
        target = "modals/usermgr-modal.lp",
    },
    {
        desc = T"Remote Assistance",
        target = "modals/assistance-modal.lp",
    },
    }
    ngx.print(ui_helper.createModalTabs(tabs))
end
%>

<form class="form-horizontal" method="post" action="modals/usermgr-modal.lp">
<%
    ngx.print(ui_helper.createMessages(message_helper.popMessages()))
%>

<fieldset>
<legend><%= T"Users list" %></legend>
<%
    ngx.print(ui_helper.createTable(umgr_columns, umgr_data, umgr_options, umgr_attributes, umgr_helpmsg))
%>
</fieldset>
</form>
</div>

<%= ui_helper.createFooter() %>

<script src="/js/srp-min.js" ></script>
<script type="text/javascript" >

    function clear_error_password()
    {
        var upass = $('.modal input[name="password"],.modal input[name="password2"]');
        upass.removeClass("tooltip-on error");
        upass.closest(".control-group").removeClass("error");
        upass.first().next().remove();
    }

    function display_error_password(msg)
    {
        var upass = $('.modal input[name="password"],.modal input[name="password2"]');
        upass.addClass("error");
        upass.closest(".control-group").addClass("error");
        upass.first().after('<span class="help-inline">' + msg + '</span>');
    }

    function clear_error_user()
    {
        var uinput = $('.modal input[name="name"]');
        uinput.removeClass("tooltip-on").removeClass("error");
        uinput.closest(".control-group").removeClass("error");
    }

    function display_error_user()
    {
        var uinput = $('.modal input[name="name"]');
        uinput.addClass("tooltip-on error");
        uinput.attr("placement", "top");
        uinput.attr("data-original-title", "User name cannot be empty");
        uinput.closest(".control-group").addClass("error");
        $('.tooltip-on').tooltip();
    }

    // "Disable" the existing handler by removing the class it matches on (tried to use the off() method of jquery to no avail)
    $(".modal .btn-table-modify").removeClass("btn-table-modify").addClass("btn-table-modify-custom");
    $(".modal .btn-table-add").removeClass("btn-table-add").addClass("btn-table-add-custom");
    $(".modal .btn-table-modify-custom,.modal .btn-table-add-custom").on("click", function () {
        clear_error_user();
        clear_error_password();

        var self = this;
        var user = $('input[name="name"]').val();
        var password = $('input[name="password"]').val();
        var password2 = $('input[name="password2"]').val();
        var salt = $('input[name="srp_salt"]').val();
        var verifier = $('input[name="srp_verifier"]').val();

        if(password !== password2) {
            display_error_password("Passwords do not match");
            return;
        }

        if(user == "") {
            display_error_user();
            return;
        }

        if(password == "") {
            if(verifier.length != 512 || salt.length != 8) {
                display_error_password("You must fill your password");
                return;
            } else {
                sendData();
                return;
            }
        }

        function sendData()
        {
            var target = $(".modal form").attr("action");
            var table = $(self).closest("table");
            var id = table.attr("id");
            var line = $(self).closest("tr");
            var index = line.index();
            var params = line.find(":input").serializeArray();
            var add_params = table.find(".additional-edit :input").serializeArray();
            var action;

            if($(self).hasClass("btn-table-add-custom")) {
                action = "TABLE-ADD";
            } else {
                action = "TABLE-MODIFY"
            }

            params = params.concat(add_params);
            params.push({
                name : "tableid",
                value : id
            });
            params.push({
                name : "stateid",
                value : table.attr("data-stateid")
            });
            params.push({
                name : "action",
                value : action
            });
            params.push({
                name : "index",
                value : index + 1
            });
            params.push(tch.elementCSRFtoken());
            tch.loadModal(target, params, function() {
                tch.scrollRowIntoView(id, index);
            });
        }

        var srp = new SRP();
        srp.generateSaltAndVerifierTheCallback(user, password, function(salt, verifier) {
            $('input[name="srp_salt"]').val(salt);
            $('input[name="srp_verifier"]').val(verifier);
            $('input[name="password"]').val(""); // clean that up no need to send it over the air
            $('input[name="password2"]').val("");
            sendData();
        });

        srp.error_message = function() {
            display_error();
        }
    });
</script>
