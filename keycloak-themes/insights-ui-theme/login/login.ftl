<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>CCE Insights — Sign in</title>
    <link rel="stylesheet" href="${url.resourcesPath}/css/login.css">
</head>
<body>
    <div class="page">
        <div class="card">

            <div class="banner">
                <div class="icon-wrap">
                    <img src="${url.resourcesPath}/img/moh-logo.png" alt="Republic of Rwanda — Ministry of Health"/>
                </div>
                <h1>CCE Insights</h1>
                <p>Care Coordination Analytics</p>
            </div>

            <div class="body">
                <h2 class="subtitle">Sign in to your account</h2>

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

                    <button type="submit">Sign in</button>
                </form>
            </div>
        </div>

        <p class="footer">Medtronic Care Coordination Engine</p>
    </div>
</body>
</html>
