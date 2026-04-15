# Templates

Drop `.json` request bodies in this folder and call them by basename:

```bash
rollbar --path /api/1/rql/jobs my-request
```

For example, `templates/my-request.json` can hold a saved RQL job body or another POST payload you reuse often.
