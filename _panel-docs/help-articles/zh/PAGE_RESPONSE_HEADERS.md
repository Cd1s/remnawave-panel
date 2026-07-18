## 响应头（Headers）

响应头（Headers）是随订阅（响应）一起发送的 HTTP 头部。

在 Remnawave 中，你可以使用 `rwEncodeBase64:` 键将头部的值编码为 base64。

下面列出了一些常用的头部，其中一部分已默认配置。

### profile-title

主要用于在客户端中显示配置文件名称的头部。

键: `profile-title`

示例值: `rwEncodeBase64:我的超棒订阅`

默认值: `rwEncodeBase64:Remnawave`

### profile-web-page-url

用于在客户端中显示配置文件网页的链接。

键: `profile-web-page-url`

示例值: `rwEncodeBase64:https://dummy.docs.rw`

默认值: `rwEncodeBase64:{{SUBSCRIPTION_URL}}`

### profile-update-interval

用于设置客户端中的订阅更新间隔。

键: `profile-update-interval`

示例值: `1`

默认值: `12`

### support-url

用于设置客户端中的支持链接。

键: `support-url`

示例值: `https://dummy.docs.rw`

默认值: `https://dummy.docs.rw`
