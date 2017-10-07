worker_processes 16
preload_app true
pid './unicorn.pid'
listen '/tmp/unicorn.sock', :backlog => 32
