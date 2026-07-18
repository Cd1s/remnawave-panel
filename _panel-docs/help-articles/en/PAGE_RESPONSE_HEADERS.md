## Headers

Headers are HTTP headers that are sent along with the subscription (response).

In Remnawave, you can use the `rwEncodeBase64:` key to encode a header value in base64.

Below is a list of popular headers. Some of them are configured by default.

### profile-title

A header that is mainly used to display the profile name in the client application.

Key: `profile-title`

Example value: `rwEncodeBase64:My awesome subscription`

Default value: `rwEncodeBase64:Remnawave`

### profile-web-page-url

Used to display a link to the profile web page in the client application.

Key: `profile-web-page-url`

Example value: `rwEncodeBase64:https://dummy.docs.rw`

Default value: `rwEncodeBase64:{{SUBSCRIPTION_URL}}`

### profile-update-interval

Used to set the subscription update interval in the client application.

Key: `profile-update-interval`

Example value: `1`

Default value: `12`

### support-url

Used to set the support link in the client application.

Key: `support-url`

Example value: `https://dummy.docs.rw`

Default value: `https://dummy.docs.rw`
