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
                    <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.8"
                              d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"/>
                    </svg>
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
