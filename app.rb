require 'sinatra/base'
require 'mysql2'
require 'mysql2-cs-bind'
require 'erubis'
require 'rack-lineprof'
require 'rack/session/dalli'

module Ishocon1
  class AuthenticationError < StandardError; end
  class PermissionDenied < StandardError; end
end

class Ishocon1::WebApp < Sinatra::Base
  session_secret = ENV['ISHOCON1_SESSION_SECRET'] || 'showwin_happy'
  use Rack::Session::Dalli, namespace: 'ishocon1', cache: Dalli::Client.new('/tmp/memcached.sock')
  #use Rack::Lineprof, profile: 'app.rb'
  set :erb, escape_html: true
  set :protection, true

  helpers do
    def config
      @config ||= {
        db: {
          socket: '/var/lib/mysql/mysql.sock',
          username: ENV['ISHOCON1_DB_USER'] || 'ishocon',
          password: ENV['ISHOCON1_DB_PASSWORD'] || 'ishocon',
          database: ENV['ISHOCON1_DB_NAME'] || 'ishocon1'
        }
      }
    end

    def db
      return Thread.current[:ishocon1_db] if Thread.current[:ishocon1_db]
      client = Mysql2::Client.new(
        socket: config[:db][:socket],
        username: config[:db][:username],
        password: config[:db][:password],
        database: config[:db][:database],
        reconnect: true
      )
      client.query_options.merge!(symbolize_keys: true)
      Thread.current[:ishocon1_db] = client
      client
    end

    def time_now_db
      Time.now - 9 * 60 * 60
    end

    def authenticate(email, password)
      user = db.xquery('SELECT SQL_CACHE id, password FROM users WHERE email = ?', email).first
      fail Ishocon1::AuthenticationError unless user[:password] == password
      session[:user_id] = user[:id]
    end

    def authenticated!
      fail Ishocon1::PermissionDenied unless current_user
    end

    def current_user
      db.xquery('SELECT SQL_CACHE id, name FROM users WHERE id = ?', session[:user_id]).first
    end

    def buy_product(product_id, user_id)
      db.xquery('INSERT INTO histories (product_id, user_id, created_at) VALUES (?, ?, ?)', \
        product_id, user_id, time_now_db)
    end

    def already_bought?(product_id)
      return false unless current_user
      count = db.xquery('SELECT SQL_CACHE count(*) as count FROM histories WHERE product_id = ? AND user_id = ?', \
                        product_id, session[:user_id]).first[:count]
      count > 0
    end

    def create_comment(product_id, user_id, content)
      db.xquery('INSERT INTO comments (product_id, user_id, content, created_at) VALUES (?, ?, ?, ?)', \
                product_id, user_id, content[0..25], time_now_db)
    end
  end

  error Ishocon1::AuthenticationError do
    session[:user_id] = nil
    halt 401, erb(:login, layout: false, locals: { message: 'ログインに失敗しました' })
  end

  error Ishocon1::PermissionDenied do
    halt 403, erb(:login, layout: false, locals: { message: '先にログインをしてください' })
  end

  get '/login' do
    session.clear
    erb :login, layout: false, locals: { message: 'ECサイトで爆買いしよう！！！！', current_user: current_user }
  end

  post '/login' do
    authenticate(params['email'], params['password'])
    redirect '/'
  end

  get '/logout' do
    session[:user_id] = nil
    session.clear
    redirect '/login'
  end

  get '/' do
    page = params[:page].to_i || 0
    max_id = db.xquery("SELECT SQL_CACHE MAX(id) AS max_id FROM products").first[:max_id]
    range_condition = "id BETWEEN #{max_id - (page + 1) * 50 + 1} AND #{max_id - page * 50}"
    comments_query = %|
      SELECT SQL_CACHE product_id, name, SUBSTRING(content, 1, 26) AS content
      FROM comments c
      INNER JOIN users u
      ON c.user_id = u.id
      WHERE product_#{range_condition}
      ORDER BY product_id DESC, c.created_at DESC
    |
    comments = db.xquery(comments_query)
                 .to_a
                 .group_by {|e| e[:product_id]}
                 .values
    products = db.xquery("SELECT SQL_CACHE id, name, image_path, price, SUBSTRING(description, 1, 70) AS description FROM products WHERE #{range_condition} ORDER BY id DESC LIMIT 50").to_a.map.with_index {|product, idx|
      product[:comments_count] = comments[idx].size
      product[:comments] = comments[idx][0..4]
      product
    }

    erb :index, locals: { products: products, current_user: current_user }
  end

  get '/users/:user_id' do
    products_query = %|
SELECT SQL_CACHE p.id, p.name, SUBSTRING(p.description, 1, 70) AS description, p.image_path, p.price, h.created_at
FROM histories as h
LEFT OUTER JOIN products as p
ON h.product_id = p.id
WHERE h.user_id = ?
ORDER BY h.id DESC
    |
    products = db.xquery(products_query, params[:user_id])

    total_pay = products.to_a.inject(0) {|sum, e| sum + e[:price] }

    user = db.xquery('SELECT SQL_CACHE id, name FROM users WHERE id = ?', params[:user_id]).first
    erb :mypage, locals: { products: products, user: user, total_pay: total_pay, current_user: current_user }
  end

  get '/products/:product_id' do
    product = db.xquery('SELECT SQL_CACHE name, image_path, price, description FROM products WHERE id = ?', params[:product_id]).first
    erb :product, locals: { product: product, already_bought: already_bought?(product[:id]), current_user: current_user }
  end

  post '/products/buy/:product_id' do
    authenticated!
    buy_product(params[:product_id], session[:user_id])
    redirect "/users/#{session[:user_id]}"
  end

  post '/comments/:product_id' do
    authenticated!
    create_comment(params[:product_id], session[:user_id], params[:content])
    redirect "/users/#{session[:user_id]}"
  end

  get '/initialize' do
    db.query('DELETE FROM users WHERE id > 5000')
    db.query('DELETE FROM products WHERE id > 10000')
    db.query('DELETE FROM comments WHERE id > 200000')
    db.query('DELETE FROM histories WHERE id > 500000')
    "Finish"
  end
end
