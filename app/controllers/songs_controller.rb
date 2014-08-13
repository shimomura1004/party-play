require 'json'
require 'yaml'
require 'audioinfo'

class SongsController < ApplicationController
  protect_from_forgery except: [:add, :skip]

  def add
    info = write_file params
    save_info info unless info.nil?
  end

  def add_url
    if params[:url]
      info = download_file_asynchronously(params)
      render :json => {status: 'ok', info: info}
    end
  end

  def skip
    Redis.current.publish 'skip', :skip
    render text: 'ok'
  end

  def index
    case params[:format]
    when "json"
      begin
        songs = Redis.current.lrange("playlist",0,10).map {|song_id| Redis.current.get(song_id)}
      rescue Redis::CannotConnectError => e
        render :json => {status: 'ok'}
        return
      end

      current_song = songs[0..0].map{|song| eval(song)}
      next_songs = (songs[1..-1] || []).map{|song| eval(song)}

      render :json => {current: current_song.first, next: next_songs}

    when "html"
      respond_to do |format|
        format.html
      end
    else
      render :text => ""
    end
  end

  private
  def dir
    File.expand_path("public/music", Rails.root).tap(&FileUtils.method(:mkdir_p))
  end

  def account
    YAML::load(File.read("#{Rails.root}/config/account.yml"))
  end

  def url(filepath)
    filename = File.basename(filepath)
    "http://#{request.host}:#{request.port}/music/#{filename}"
  end

  def save_audiofile(id, file)
    filename = id + File.extname(file.original_filename)
    path = File.expand_path(filename, dir)
    IO.binwrite(path, file.read)

    return path
  end

  def save_artwork(id, image_data)
    ext = nil

    db = {
      Regexp.new("\xFF\xD8".force_encoding("BINARY"), Regexp::FIXEDENCODING) => ".jpg",
      Regexp.new("\x89PNG".force_encoding("BINARY"), Regexp::FIXEDENCODING) => ".png",
      Regexp.new("GIF8[79]a".force_encoding("BINARY"), Regexp::FIXEDENCODING) => ".gif"
    }

    # remove needless header from image data
    db.each do |mark, type|
      match_index = (mark =~ image_data)
      if match_index and match_index < 20
        ext = type
        image_data = image_data.slice(match_index .. -1)
        break
      end
    end

    filename = "#{id}.artwork#{ext}"
    path = File.expand_path(filename, dir)
    IO.binwrite(path, image_data)

    return path
  end

  def write_file(params)
    info = {}
    params.slice(:title, :artist).each{|k,v| info[k] = CGI.unescape(v)}

    id = Time.now.strftime("%Y%m%d%H%M%S%L")

    begin
      filepath = save_audiofile(id, params[:file])
      info[:path] = filepath


      info[:url] = url(filepath)

      audioinfo = AudioInfo.open(filepath)
    rescue => e
      Rails.logger.error(e)
      File::delete(filepath) if filepath and File::exists?(filepath)
      return nil
    end

    info[:title]   ||= audioinfo.title
    info[:artist]  ||= audioinfo.artist

    if params[:artwork]
      filepath = save_artwork(id, params[:artwork].read)
      info[:artwork] = url(filepath)
    elsif audioinfo.picture
      filepath = save_artwork(id, audioinfo.picture)
      info[:artwork] = url(filepath)
    else
      info[:artwork] = ""
    end

    info
  end

  def download_file_asynchronously(params)
    url = params[:url]
    json = JSON::parse(`youtube-dl --dump-json "#{url}"`)

    Process::fork do
      download_command = "youtube-dl -x"
      if account[json["extractor"]]
        username = account[json["extractor"]]["username"]
        password = account[json["extractor"]]["password"]
        download_command = "#{download_command} -u #{username} -p #{password}"
      end

      time = Time.now.strftime("%Y%m%d%H%M%S%L")
      video_filename = "#{time}.#{json['ext']}"

      puts `#{download_command} -o "#{dir}/#{video_filename}" "#{url}"`
      audio_filename = nil
      ["m4a", "mp3"].each do |ext|
        filename = "#{time}.#{ext}"
        audio_filename = filename if File.exists?("#{dir}/#{filename}")
      end

      title = json["title"]
      artist = json["uploader"]
      path = File.expand_path(audio_filename, dir)
      url =  "http://#{request.host}:#{request.port}/music/#{audio_filename}"
      artwork_url = json["thumbnail"]

      save_info(title: title, artist: artist, path: path, url: url, artwork: artwork_url)
    end

    json
  end

  def save_info(info)
    count = Redis.current.incr "song-id"
    id = "song:#{count}"
    Rails.logger.debug "Add '#{id}' with #{info.inspect}"
    Redis.current.set id, info
    Redis.current.rpush "playlist", id
  end
end
