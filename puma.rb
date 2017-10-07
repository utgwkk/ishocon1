workers 4
preload_app!
bind 'unix:///tmp/unicorn.sock'
pidfile '/tmp/puma.pid'
