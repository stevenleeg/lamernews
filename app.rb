# Copyright 2011 Salvatore Sanfilippo. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 
#    1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 
#    2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY SALVATORE SANFILIPPO ''AS IS'' AND ANY EXPRESS
# OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN
# NO EVENT SHALL SALVATORE SANFILIPPO OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# 
# The views and conclusions contained in the software and documentation are
# those of the authors and should not be interpreted as representing official
# policies, either expressed or implied, of Salvaore Sanfilippo.

require 'rubygems'
require 'redis'
require 'page'
require 'app_config'
require 'sinatra'
require 'json'
require 'digest/sha1'

before do
    if !$r
    then
        $r = Redis.new(:host => RedisHost, :port => RedisPort)
        H = HTMLGen.new
    end
    $user = nil
    auth_user(request.cookies['auth'])
end

get '/' do
    H.set_title "Top News - #{SiteName}"
    H.page {
        H.h2 {"Top news"}
    }
end

get '/login' do
    H.set_title "Login - #{SiteName}"
    H.page {
        H.login {
            H.form(:name=>"f") {
                H.label(:for => "username") {"username"}+
                H.inputtext(:name => "username")+
                H.label(:for => "password") {"password"}+
                H.inputtext(:name => "password")+H.br+
                H.checkbox(:name => "register", :value => "1")+
                "create account"+H.br+
                H.button(:name => "do_login", :value => "Login")
            }
        }+
        H.div(:id => "errormsg"){}+
        H.script(:type=>"text/javascript") {'
            $(document).ready(function() {
                $("input[name=do_login]").click(login);
            });
        '}
    }
end

get '/logout' do
    update_auth_token($user["id"]) if $user
    redirect "/"
end

get '/api/login' do
    auth = check_user_credentials(params[:username],params[:password])
    if auth 
        return {:status => "ok", :auth => auth}.to_json
    else
        return {
            :status => "err",
            :error => "No match for the specified username / password pair."
        }.to_json
    end
end

get '/api/create_account' do
    auth = create_user(params[:username],params[:password])
    if auth 
        return {:status => "ok", :auth => auth}.to_json
    else
        return {
            :status => "err",
            :error => "Username is busy. Please select a different one."
        }.to_json
    end
end

get '/api/submit' do
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    # We can have an empty url or an empty first comment, but not both.
    if (!check_params "title",:url,:text) or (params[:url].length == 0 and
                                              params[:text].length == 0)
        return {
            :status => "err",
            :error => "Please specify a news title and address or text."
        }.to_json
    end
    # Make sure the URL is about an acceptable protocol, that is
    # http:// or https:// for now.
    if params[:url].length != 0
        if params[:url].index("http://") != 0 and
           params[:url].index("https://") != 0
            return {
                :status => "err",
                :error => "We only accept http:// and https:// news."
            }.to_json
        end
    end
    news_id = submit_news(params[:title],params[:url],params[:text],$user["id"])
    return  {
        :status => "ok",
        :news_id => news_id
    }.to_json
end

# Check that the list of parameters specified exist.
# If at least one is missing false is returned, otherwise true is returned.
#
# If a parameter is specified as as symbol only existence is tested.
# If it is specified as a string the parameter must also meet the condition
# of being a non empty string.
def check_params *required
    required.each{|p|
        if !params[p] or (p.is_a? String and params[p].length == 0)
            return false
        end
    }
    true
end

def check_params_or_halt *required
    return if check_parameters *required
    halt 500, H.h1{"500"}+H.p{"Missing parameters"}
end

def application_header
    navitems = [    ["top","/"],
                    ["latest","/latest"],
                    ["submit","/submit"]]
    navbar = H.nav {
        navitems.map{|ni|
            H.a(:href=>ni[1]) {H.entities ni[0]}
        }.inject{|a,b| a+"\n"+b}
    }
    rnavbar = H.rnav {
        if $user
            text = $user['username']
            link = "/user/"+H.urlencode($user['username'])
            H.a(:href => "/user/"+H.urlencode($user['username'])) { 
                $user['username']+" (#{$user['karma']})"
            }+" | "+
            H.a(:href => "/logout") {"logout"}
        else
            H.a(:href => "/login") {"login / register"}
        end
    }
    H.header {
        H.h1 {
            H.entities SiteName
        }+navbar+" "+rnavbar
    }
end

def application_footer
    H.footer {
        "Lamer News source code is located "+
        H.a(:href=>"http://github.com/antirez/lamernews"){"here"}
    }
end

################################################################################
# User and authentication
################################################################################

# Try to authenticate the user, if the credentials are ok we populate the
# $user global with the user information.
# Otherwise $user is set to nil, so you can test for authenticated user
# just with: if $user ...
#
# Return value: none, the function works by side effect.
def auth_user(auth)
    return if !auth
    id = $r.get("auth:#{auth}")
    return if !id
    user = $r.hgetall("user:#{id}")
    $user = user if user.length > 0
end

# Return the hex representation of an unguessable 160 bit random number.
def get_rand
    rand = "";
    File.open("/dev/urandom").read(20).each_byte{|x| rand << sprintf("%02x",x)}
    rand
end

# Create a new user with the specified username/password
#
# Return value: the auth token if the user was correctly creaed.
#               nil if the username already exists.
def create_user(username,password)
    return nil if $r.exists("username.to.id:#{username.downcase}")
    id = $r.incr("users.count")
    auth_token = get_rand
    $r.hmset("user:#{id}",
        "id",id,
        "username",username,
        "password",hash_password(password),
        "ctime",Time.now.to_i,
        "karma",10,
        "about","",
        "email","",
        "auth",auth_token)
    $r.set("username.to.id:#{username.downcase}",id)
    $r.set("auth:#{auth_token}",id)
    return auth_token
end

# Update the specified user authentication token with a random generated
# one. This in other words means to logout all the sessions open for that
# user.
#
# Return value: on success the new token is returned. Otherwise nil.
# Side effect: the auth token is modified.
def update_auth_token(user_id)
    user = get_user_by_id(user_id)
    puts user.inspect
    return nil if !user
    $r.del("auth:#{user['auth']}")
    new_auth_token = get_rand
    $r.hmset("user:#{user_id}","auth",new_auth_token)
    $r.set("auth:#{new_auth_token}",user_id)
    return new_auth_token
end

# Turn the password into an hashed one, using
# SHA1(salt|password).
def hash_password(password)
    Digest::SHA1.hexdigest(PasswordSalt+password)
end

# Return the user from the ID.
def get_user_by_id(id)
    $r.hgetall("user:#{id}")
end

# Return the user from the username.
def get_user_by_username(username)
    id = $r.get("username.to.id:#{username.downcase}")
    return nil if !id
    get_user_by_id(id)
end

# Check if the username/password pair identifies an user.
# If so the auth token is returned, otherwise nil is returned.
def check_user_credentials(username,password)
    hp = hash_password(password)
    user = get_user_by_username(username)
    return nil if !user
    (user['password'] == hp) ? user['auth'] : nil
end

################################################################################
# News
################################################################################

# Add a news with the specified url or text.
#
# If an url is passed but was already posted in the latest 48 hours the
# news is not inserted, and the ID of the old news with the same URL is
# returned.
#
# Return value: the ID of the inserted news, or the ID of the news with
# the same URL recently added.
def submit_news(title,url,text,user_id)
    # If we don't have an url but a comment, we turn the url into
    # text://....first comment..., so it is just a special case of
    # title+url anyway.
    textpost = url.length == 0
    if url.length == 0
        url = "text://"+text[0...CommentMaxLength]
    end
    # Check for already posted news with the same URL.
    if !textpost and (id = $r.get("url+"+url))
        return id
    end
    # We can finally insert the news.
    ctime = Time.new.to_i
    id = $r.incr("news.count")
    $r.hmset("news:#{id}",
        "id", id,
        "title", title,
        "url", url,
        "user_id", user_id,
        "ctime", ctime,
        "score", 0,
        "rank", 0)
end
