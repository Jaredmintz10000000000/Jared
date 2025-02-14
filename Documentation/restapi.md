# REST API

If enabled, Jared exposes a webserver on the port `3000`. You can configure what port it starts up in the `config.json` file under the `webserver.port` property.

## Endpoints
`POST` `/message` 

This allows you to send text messages to any Person or Group. You will receive a 200 status code if Jared successfully parsed your request and passed it on to the handler. Otherwise, you may receive a 400 bad request exception. Note that the message will not be send if Jared is not "enabled" in the UI.

```
{
  "body": {
    "message": "Jared is an amazing app"
  },
  "recipient": {
    "handle": "handle@email.com",
  }
}
```

You may also specify attachments (such as images) to send. Simply specify file paths in the attachments array of the request body. Note that the file path specified must be accessible by the user that Jared is running under.

```
{
  "attachments": [
    {
      "filePath": "/Users/username/Pictures/funnyimage.jpeg"
    }
  ],
  "recipient": {
    "handle": "handle@email.com"
  }
}
```
