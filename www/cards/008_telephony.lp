<%
-- Enable localization
gettext.textdomain('webui-voice')

datamodel = require ("datamodel")
ui_helper = require ("web.ui_helper")
content_helper = require ("web.content_helper")

local session = ngx.ctx.session
if session:hasAccess("/modals/mmpbx-global-modal.lp") and session:hasAccess("/modals/mmpbx-profile-modal.lp") and session:hasAccess("/modals/mmpbx-service-modal.lp") and session:hasAccess("/modals/mmpbx-log-modal.lp") and session:hasAccess("/modals/mmpbx-dect-modal.lp") then
    local currentuserrole = session.getrole()

    local sipprofile_path = "uci.mmpbxrvsipnet.profile."
    local sipprofile_ubus_path = "rpc.mmpbx.profile.@"

    local sipprofile_content = content_helper.getMatchedContent (sipprofile_path)

    local mmpbx_state, error = datamodel.get("uci.mmpbx.mmpbx.@global.enabled")
    if mmpbx_state then
        mmpbx_state = mmpbx_state[1].value
    end

    modalPath = "/modals/mmpbx-dect-modal.lp"

    local mmpbx_info
    if mmpbx_state and mmpbx_state == "1" then
      mmpbx_info = T"Telephony enabled"
    else
      mmpbx_info = T"Telephony disabled"
    end

    local sipprofile_info = {}
    if currentuserrole == "guest" then
       local v = {}
       for _, v in pairs (sipprofile_content) do
           local name = string.match (v.path, "@([^%.]+)")
	   if v.userfriendlyname ~= nil and v.userfriendlyname ~= "" then
              sipprofile_info[name] = v.userfriendlyname
	   else
	      sipprofile_info[name] = v.uri
	   end
        end
     end

%>

<div class="span3">
  <div class="smallcard">
    <%
    ngx.print(ui_helper.createCardHeaderNoIcon(T"Telephony", modalPath, nil, nil))
    %>
    <div class="content">
    <%
	local html = {}
        table.insert(html, ui_helper.createSimpleLight(mmpbx_state, mmpbx_info))
        ngx.print (html)
        if currentuserrole == "guest" then
           local name, value = "", ""
           local reg_info = {
	     ["0"] = "Unregistered",
             ["1"] = "Registered",
	     ["2"] = "Registering",
	   }
	   local reg_num = {["0"] = 0,["1"] = 0,["2"] = 0}
	   local reg_state = {"1","2","0"}
	   for name, value in pairs (sipprofile_info) do
               local res = datamodel.get (sipprofile_ubus_path..name..".sipRegisterState")
	       if (type(res) == "table") then
	          if (res[1].value == "Registered") then
		      reg_num["1"] = reg_num["1"] + 1
		  elseif (res[1].value == "Registering") then
		      reg_num["2"] = reg_num["2"] + 1
	          end
	       end
	       reg_num["0"] = reg_num["0"] + 1
            end
	    reg_num["0"] = reg_num["0"] - reg_num["1"] - reg_num["2"]
            ngx.print('<p class="subinfos">')
            for _, v in pairs (reg_state) do
                ngx.print(
                string.format(T'%s: %d<br />', reg_info[v], reg_num[v])
                )
            end
            ngx.print('</p>')
         end
    %>
    </div>
  </div>
</div>

<%
end
%>
