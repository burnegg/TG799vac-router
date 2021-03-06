<%
-- Enable localization
gettext.textdomain('webui-core')

local triesbeforemsg = 3
local content_helper = require("web.content_helper")

local cui = {
  s_defaultuser = "uci.web.sessionmgr.@default.default_user",
  defaultuser = "uci.web.uiconfig.@uidefault.defaultuser",
  nsplink = "uci.web.uiconfig.@uidefault.nsplink",
  adusrname = "uci.web.user.@usr_admin.name",
  legacysalt = "uci.web.user.@usr_admin.legacy_salt",
}
content_helper.getExactContent(cui)

local currentuser = ngx.ctx.session:getusername()
local getargs = ngx.req.get_uri_args()
local dm = require("datamodel")

if ngx.req.get_method() == "POST" then
  local post_args = ngx.req.get_post_args()
  local ret = false

  --if the post is to reset password, it means the legacy_salt should be reset
  if post_args.resetpass then
    ret = ngx.ctx.session:changePassword(post_args.salt, post_args.verifier)
    if ret then
      dm.set("uci.web.user.@usr_admin.legacy_salt", "")
      dm.apply()
    end
  end

  if post_args.do_signout then
    --NG-9496:In Advanced UI，the signout doesn't works.
    --The param from=adv comes from action.js
    if getargs.from == "adv" then  --User click signout in Advanced UI (cards)
      --Clear the current session
      ngx.ctx.session:logout()
      if cui.s_defaultuser ~= "" then
        --default user exists, access the advanced WEBUI with default user.
        ngx.redirect("/gateway.lp")
      else
        --store the "/gateway.lp" and then redirect to "/login.lp",
        --and redirect ot "/gateway.lp" after authentication
        ngx.ctx.session:store("lasturi", "/gateway.lp")
        --Show the uri without variable.
        ngx.redirect("/login.lp")
      end
    else  --User clicks the signout in RefreshUI.
      --if we changed the default user to non default user,the s_defaultuser will be null
      if cui.s_defaultuser ~= "" then
        --Non default usr restored to the default user, and later click logout.
        --The session temporary data need to be cleared.
        if currentuser ~= cui.s_defaultuser then
          ngx.ctx.session:logout()
        end
        --default user needn't to login, so we redirect to home page.
        ngx.redirect("/")
      else
        --the default user is NOT admin, the logout will redirect to login page (handled in action.js),
        --the session temporary data will be cleared here.
        ngx.ctx.session:logout()
      end
    end
  end
end

--NG-8926:After Signing in on the advaned user page you should be redirected to the Advance GUI
--The user clicked the SIGNIN in advanced UI,
--Store the "/gateway.lp" temporary,
--And redirect to "gateway.lp" after authentication.
if ngx.req.get_method() == "GET" then
  if getargs.from == "adv" then
    --store the "/gateway.lp" and then redirect to "/login.lp"
    ngx.ctx.session:store("lasturi", "/gateway.lp")
    ngx.redirect("/login.lp")
  end
end
%>
<!DOCTYPE HTML>
<%= string.format('<html lang="%s">', gettext.language()) %>
<head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta charset="UTF-8">
    <meta name="CSRFtoken" content="<%= ngx.ctx.session:getCSRFtoken() %>">
    <link href="/css/gw.css" rel="stylesheet">
    <link href="/css/responsive.css" rel="stylesheet">
    <!--[if IE 7]><link rel="stylesheet" href="/css/font-awesome-ie7.css"><![endif]-->
    <script src="/js/main-min.js" ></script>
    <!--[if lt IE 9]> <script src="/js/media-min.js"></script> <![endif]-->
    <script src="/js/srp-min.js" ></script>
    <title><%= T"Login" %></title>
</head>
<body>
  <div class="container">
    <div class="logo-technicolor"><img src="/img/logo.gif"></div>
    <div class="row">
      <div class="offset4 span4">
        <div class="login">
        <form class="form-horizontal">
          <fieldset>
                <h2><%= T"Sign in" %></h2>
            <div id="erroruserpass" class="alert alert-error hide">
               <strong><%= T"Invalid Username or Password" %></strong>
            </div>
            <div class="control-group">
                <label for="srp_username"><div class="label-icon">
                    <i class="icon-user icon-large"></i>
                </div></label>
                <input class="span3" type="text" placeholder="<%= T"Your username" %>" id="srp_username" value="<%= cui.defaultuser %>" autofocus><br><br>
            </div>
            <div class="control-group">
                <label for="srp_password"><div class="label-icon"><i class="icon-lock icon-large"></i></div></label>
                <input class="span3" type="password" placeholder="<%= T"Your password" %>" id="srp_password"><br><br>
            </div>
            <div id="defaultpassword" class="alert alert-info hide">
                <%= T"If you haven't changed it, the default password can be found on the sticker under your gateway (it's called <strong>\"access code\"</strong>)" %>
            </div>
            <div class="pull-right"><div id="sign-me-in" class="btn btn-primary btn-large"><%= T"Sign in" %></div></div>
          </fieldset>
        </form>
      </div>
      </div>
    </div>
    <div class="row"><div class="copyright span12"><p>&copy; Technicolor 2014</p></div></div>
  </div>
<script>
$(document).ready(
  function() {
    var triesbeforemsg = <%= triesbeforemsg %>;
    var tries = 0;
    var password = "";
    var tmppassword = "";

    // Set the focus on the first input field
    $('form:first *:input[type!=hidden]:first').focus();
    // Handle press of enter. Could be handled by adding a hidden input submit but
    // this requires a lot of css tweaking to get it right since display:none does
    // not work on every browser. So go for the js way
    $('form input').keydown(function(e) {
        if(e.which == 13 || e.which == 10) {
            e.preventDefault();
            $("#sign-me-in").click();
        }
    });

    $("#sign-me-in").on("click", function () {
      $(this).text('<%= T"Verifying" %>');
      password = $("#srp_password")[0].value;
      tmppassword = password;

      //to get the legacy_salt & is not null, and confirm the username is adminusername, do migration
      var legacysalt = "<%= cui.legacysalt %>";
      var aduser = "<%= cui.adusrname %>";
      if (("" != legacysalt) && (aduser == $("#srp_username")[0].value))
      {
          var hashObj = new jsSHA((legacysalt+tch.stringToHex(password)), "HEX");
          password = hashObj.getHash("SHA-1", "HEX");
      }
      var srp = new SRP();
      srp.success = function() {
        //when do migration the legacy_salt is null and current user is admin, do the reset pass operation
        if (("" != legacysalt) && (aduser == $("#srp_username")[0].value))
        {
          srp.generateSaltAndVerifierTheCallback($("#srp_username")[0].value, tmppassword, function(salt, verStr) {
            $.post("/login.lp", { CSRFtoken:$("meta[name=CSRFtoken]").attr("content"), salt:salt, verifier:verStr, resetpass:"1" },
              function reloadPage(){
                if (window.location.pathname.search(/\/login\.lp$/) == -1)
                  window.location.reload();
                else
                  window.location = "/";
              });
          });
        }
        else
        {
          if (window.location.pathname.search(/\/login\.lp$/) == -1)
            window.location.reload();
          else
            window.location = "/";
        }
      }
      srp.error_message = function() {
        $("#sign-me-in").text('<%= T"Sign in" %>');
        $("#erroruserpass").show();
        $(".control-group").addClass("error");

        tries++;
        if(triesbeforemsg > 0 && tries >= triesbeforemsg) {
            $("#defaultpassword").show();
        }
      }
      srp.identify("/authenticate", $("#srp_username")[0].value, password);
    });
  })
</script>
</body>
</html>
