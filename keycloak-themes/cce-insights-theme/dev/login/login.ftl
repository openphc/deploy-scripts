<#-- Dev login page for the Insights UI: unbranded (no country / ministry logos or text).
     Rwanda keeps its own branded theme in keycloak-themes/insights-ui-theme. -->
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>CCE Insights — Sign in</title>
    <link rel="stylesheet" href="${url.resourcesPath}/css/login.css">
</head>
<body>
    <div class="top-bar">
        <div class="top-bar-left">Care Coordination Insights</div>
        <div class="top-bar-right">Care Coordination Engine</div>
    </div>

    <div class="page">
        <div class="card">

            <div class="banner">
                <h1>Care Coordination Insights</h1>
                <p>Care coordination and data insights</p>
            </div>

            <div class="body">
                <h2 class="subtitle">Sign in to continue</h2>

                <form action="${url.loginAction}" method="post">
                    <input type="hidden" name="credentialId" value="${(auth.selectedCredential!'')}"/>

                    <div class="field">
                        <label for="username">Username</label>
                        <input id="username" name="username" type="text"
                               autocomplete="username" autofocus
                               value="${(login.username!'')}"/>
                    </div>

                    <div class="field">
                        <label for="password">Password</label>
                        <input id="password" name="password" type="password"
                               autocomplete="current-password"/>
                    </div>

                    <#if message?has_content && message.type == "error">
                        <div class="error-box">${message.summary}</div>
                    </#if>

                    <button type="submit">Sign In</button>
                </form>

                <p class="footer">Authorized users only</p>
            </div>
        </div>
    </div>
</body>
</html>
