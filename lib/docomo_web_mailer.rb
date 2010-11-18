#= ドコモWebメールクライアント
# ドコモWebメール
# http://dwmail.jp/
# のメールを読みます。
#
#==example
# メールを forwarding_mail_address へ転送する。
#  mailer = DocomoWebMailer.new
#  mailer.login( login_id, password )
#  maillist = mailer.mail_list_start(mailer.mail_label_list[:inbox],10) 
#  #nextmaillist = mailer.mail_list_get(maillist,11,10)
#  Net::SMTP.start( your_smtp_server, 25 ) {|smtp|
#    for mail in maillist
#      puts "#{mail.uid}:#{mail.subject} (#{mail.from})"
#      smtp.send_mail mailer.make_mail_to_smtp( mail ), mail.from[0][1], forwarding_mail_address
#    end
#  }
#
require 'rubygems'
require 'json'
require 'mechanize'
require 'cgi'
require 'base64'

class DocomoWebMailer
  # メールボックスの最大値？
  MAX_SIZE=10000
  # コンストラクタ
  def initialize()
    @agent = Mechanize.new
    @id = 0
    @agent.user_agent_alias = 'Mac Safari'
  end
  # ログインする。失敗するとexception
  def login(id,password)
    page = @agent.get("http://dwmail.jp/")
    form = page.form_with(:name => "f1")
    raise "login error: cant find login form" unless form
    form.field_with(:name => "uname").value = id
    form.field_with(:name => "pass").value = password
    res = @agent.submit(form)
    raise "login error (id/pass illegal) " if res.form_with(:name => "f1")
  end
  # MailLabel のメールを得る。uid順。limit個。Maillistを返す。
  # maillabel の値がSymbolならサーバフォルダ、文字列ならユーザフォルダ。
  def mail_list_start(maillabel,limit)
    place = [ A(:server_folder), A(maillabel) ]
    if maillabel.is_a? MailLabel
      place = [ A(maillabel.place), A(maillabel.index) ]
    elsif maillabel.is_a? String
      place[0]['$A']="user_folder"
    end
    Maillist.new( *rcp("mail_list_start",[ 1, T( nil, T(
        # 得たいフォルダの場所
        [ T(*place) ],
        # 不明
        [ ],
        # 不明
        [ T( A(:client_flag), A(:recent) ) ],
        # 得たい付加情報？
        [ A(:server_flag), A(:client_flag), A(:server_folder), A(:user_folder), A(:user_flag) ]
        ) ),
      # 並び順と数？
      T( T( A(:plain), A(:uid) ), A(:descending), nil, limit ),
      # 不明
      nil, MAX_SIZE, MAX_SIZE ]) )
  end
  # Maillistの続きのメールを得る。uid順。startからlimit個。新しいMaillistを返す。
  def mail_list_get(maillist, start,limit )
    Maillist.new( *rcp( "mail_list_get", [ maillist.sign, T( T( A(:plain), A(:uid) ), A(:descending), start, limit ), MAX_SIZE ] ) )
  end
  # uid で指定したメールの全パート情報を得る。Mailpartsを返す。
  # uid は to_uid によって変換される
  def mail_get_parts(uid)
    Mailparts.new *rcp("mail_get_parts", [ to_uid(uid), [ T( A(:bodypref), [ "*/*" ] ), T( A(:bodyparse), A(:off) ) ], MAX_SIZE ])
  end
  # そのパートの添付ファイルを得る。String型のバイナリデータ。
  # mimepart は Mimepart型
  def attachment(mimepart)
    url = "/pc/attachment.php?url=#{u(mimepart.attache_info)}"
    url += "&df=#{u(mimepart.filename.to_s)}" if mimepart.filename
    @agent.get_file(url)
  end
  # ラベル(フォルダ)の一覧 MailLabelList を得る。
  def mail_label_list
    MailLabelList.new( *rcp( "mail_label", [ [
      T( A(:list), [ A(:server_folder) ], A(:ascending) ),
      T( A(:list), [ A(:user_folder) ], A(:ascending) ),
      T( A(:list), [ A(:user_flag) ], A(:ascending) )
    ], 10000 ] ) )
  end
  # uid で指定したメールのヘッダ(AllMailHeaders)を得る。
  # uid は to_uid によって変換される
  def mail_get_headers(maillistitem)
    AllMailHeaders.new *rcp( "mail_get_headers", [ to_uid(maillistitem), A(:infinity) ] )
  end
  # uid で指定したメールのSMTP送信用テキストを作る
  # uid は to_uid によって変換される
  def make_mail_to_smtp(uid)
    Builder.new(self).build( uid )
  end
  # uid で指定したメールにclient_flagをたてる。
  # uid は to_uid によって変換される
  def append_client_flag(uid,flag="flagged")
    rcp( "mail_label", [ [ T( A(:append), T( A(:client_flag), A(flag) ), null, [ to_uid(uid) ] ) ], 10000 ] )
  end
  # uid で指定したメールからclient_flagを外す。
  # uid は to_uid によって変換される
  def remove_client_flag(uid,flag="flagged")
    rcp( "mail_label", [ [ T( A(:remove), T( A(:client_flag), A(flag) ), null, [ to_uid(uid) ] ) ], 10000 ] )
  end
  # maillistitem を uid にする。文字列なら数値化、数値以外ならuidプロパティーの値を返す
  def to_uid( maillistitem )
    maillistitem = maillistitem.to_i if maillistitem.is_a? String
    maillistitem = maillistitem.uid unless maillistitem.is_a? Numeric
    maillistitem
  end
  
  def A(str) # :nodoc:
    {'$A'=>str.to_s}
  end
  def T(*array) # :nodoc:
    {'$T'=>array}
  end
  
  # SMTPサーバに送信するためのメールテキストを作成する。
  # 他のメールソフト・メールライブラリで扱うための中間形式としても。
  class Builder
    @mailer
    def initialize(mailer)
      @mailer = mailer
    end
    # uid からメールテキストを作成する
    # 引数 uid には to_uid が適用される。
    def build(uid)
      build_from @mailer.mail_get_headers(uid), @mailer.mail_get_parts(uid) 
    end
    # header と parts からメールテキストを作成する
    def build_from(headers,parts)
      headers.multipart? ? make_mail_to_smtp_multipart( headers, parts ) : make_mail_to_smtp_singlepart( headers, parts.parts[0] )
    end
      
    # AllMailHeaders と Mimepart からメールのSMTP送信用テキストを作る（シングル）
    def make_mail_to_smtp_singlepart(headers,part)
      headers.to_s + "\n\n" + @mailer.attachment( part )
    end
    # AllMailHeaders と Mailparts からメールのSMTP送信用テキストを作る（マルチパート）
    def make_mail_to_smtp_multipart(headers,parts)
      raise "unknown type header #{text}" unless headers.content_type =~ /boundary=(.*)$/
      boundary = $1.dup.strip.gsub(/^"(.*)"$/,'\1').gsub(/^'(.*)'$/,'\1')
      
      headers.to_s +
      "\n\n--#{boundary}\n" +
      parts.parts.map{|part| part_to_mail(part).join("\n")}.join("\n--#{boundary}\n") +
      "\n--#{boundary}--\n"
    end
    # Mimepart をsmtp bodyに
    def part_to_mail(part)
      body = @mailer.attachment( part )
      content_type = part.content_type
      is_text = content_type =~ /^text\//
      mail = []
      mail << "Content-Type: #{content_type}"
      mail << "Content-Transfer-Encoding: #{is_text ? '8bit' : 'base64' }"
      mail << "Content-ID: #{part.contentid}" if part.contentid
      mail << "Content-Disposition: #{part.disposition_with_filename}" if part.disposition
      mail << ""
      mail << ( is_text ? body : Base64.encode64(body) )
      mail
    end
  end
  # rcp 1.0 にパラメータを投げる
  def rcp( method,params )
    @id += 1
    result = Parser.rcp_to_ruby(JSON.parse(@agent.post("http://pc.dwmail.jp/api/base/rpc/1.0", {
      :id => @id.to_s,
      :method => method.to_s,
      :params => params,
      :version=>"1.1"
    }.to_json ).body))
    unless result["error"]
      return result["result"]
    else
      require 'pp'
      pp result['error']
      pp params
      raise "error ! #{result['error']}"
    end
  end
  # rcp で返ってきたデータをRubyフレンドリーにする
  class Parser
    # rcp で返ってきたHashデータをRubyフレンドリーにする
    def self.hash_to_ruby(data)
      ret = {}
      for k,v in data
        ret[k]=rcp_to_ruby(v)
      end
      return ret
    end
    # rcp で返ってきたデータをRubyフレンドリーにする
    def self.rcp_to_ruby(data)
      case data
      when Hash
        if data.keys.size==1
          case data.keys[0]
          when '$T'
          if data["$T"].is_a? Array
              return TArray.new(data)
            end
          when '$A'
            if data["$A"].is_a? String
              return data["$A"].to_sym
            end
          end
        end
      if data['$R'] and data['$R'].is_a? String
          # data type is data['$R']
          case data['$R']
          when 'mailheaders'
            return Mailheaders.new( data )
          when 'mailsummary'
            return Mailsummary.new( data )
          when 'mimepartspec'
            return Mimepartspec.new( data )
          end
      end
        return hash_to_ruby(data)
      when Array
        ret = []
        for v in data
          ret << rcp_to_ruby(v)
        end
        return ret
      end
      return data
    end
  end
  # Structの用に扱えるハッシュ。{ '$R'=>クラス名, .... } 形式のハッシュを扱うために用いる
  class RHash
    def initialize(data)
      raise "invalid parameta" unless data.is_a? Hash
      @data = Parser.hash_to_ruby(data)
      @data.delete('$R')
    end
    # ハッシュのキーをメソッドのようにも使える
    def method_missing(sym, *args, &block)
      if @data.has_key? sym.to_s
        @data[sym.to_s]
      else
        @data.send sym, *args, &block
      end
    end
    def inspect #:nodoc:
      "#{self.class.to_s.split('::').last}"+@data.inspect
    end
  end
  # { '$T'=> [ ] } 形式の配列データ
  class TArray < Array
    def initialize(data)
      super(Parser.rcp_to_ruby(data['$T']))
    end
    def inspect #:nodoc:
      "T"+super
    end
  end
  # メールのヘッダ
  # 主なプロパティーに次の値がある
  # cc           :: ccの宛先 ( ["ラベル","メールアドレス"]の配列 )
  # from         :: 差出人   ( ["ラベル","メールアドレス"]の配列 )
  # bcc          :: bccの宛先( ["ラベル","メールアドレス"]の配列 )
  # to           :: toの宛先 ( ["ラベル","メールアドレス"]の配列 )
  # date         :: 日付(エポック秒)
  # subject      :: メールタイトル（デコード済み）
  # othres       :: その他のヘッダ( [ "ヘッダ名:値" ] の配列 )
  # in_replay_to :: 用途不明
  # references   :: 用途不明
  # message_id   :: メッセージID
  class Mailheaders < RHash
    def initialize(data)
      super
    end
  end
  # メールのサマリ。一覧表示などに使う
  # 主なプロパティーに次の値がある
  # bytes        :: メールのバイト数
  # mailheaders  :: メールのヘッダ(Mailheadersクラス)
  # uid          :: ユニークid
  # versionid    :: 用途不明
  # attachments  :: 添付ファイル名のリスト
  # created      :: 受信日(エポック秒)
  class Mailsummary < RHash
    def initialize(data)
      super
    end
    # メールのヘッダ(Mailheadersクラス)
    def mailheaders
      @data["mailheaders"]
    end
    def method_missing(sym, *args, &block)
      if @data.has_key? sym.to_s
        @data[sym.to_s]
      elsif mailheaders.has_key? sym.to_s
        mailheaders[sym.to_s]
      end
    end
  end
  # mimeパートのヘッダ
  # 主なプロパティーに次の値がある
  # conentid     :: Content-ID
  # bytes        :: 用途不明
  # content_type :: Content-Type
  # disposition  :: Content-Disposition
  # filename     :: ファイル名
  # first_byte_offset :: 用途不明
  # vertionid    :: 用途不明
  class Mimepartspec < RHash
    def initialize(data)
      super
    end
    # ファイル名付きのContent-Dispositionを得る
    def disposition_with_filename
      @data['filename'] ? "#{@data['disposition']}; filename=#{@data['filename']}" : @data['disposition']
    end
  end
  # メールのリストのアイテム
  class MailListItem
    # リスト内での位置( 一番上が1 )
    attr_reader :order
    # メールのサマリ(Mailsummary)
    attr_reader :summary
    # 用途不明
    attr_reader :flag
    def initialize( order, summary, flag )
      @order , @summary, @flag = order, summary, flag
    end
    # summary に委譲
    def method_missing(sym, *args, &block)
      @summary.send sym, *args, &block
    end
  end
  # メールの一つのmimeパート
  class Mimepart
    # Mimepartspec
    attr_reader :spec
    # メール本文（HTML化されている）
    attr_reader :body
    # 用途不明。ヘッダが [ ["content-type", "text/plain"] ] のような形で入るようだ
    attr_reader :inline_head
    # attache を得るためのキー
    attr_reader :attache_info
    def initialize( specs, inline )
      @spec, @attache_info = specs
      @inline_head, @body = inline if inline
    end
    # spec に委譲
    def method_missing(sym, *args, &block)
      @spec.send sym, *args, &block
    end
    # より正しい content-type を得る( inline_head に content-type があればそちらを持ってくる )
    def content_type_more(part)
      for n,v in inline_head
        return v if n == 'content-type'
      end if inline_head
      return @spec.content_type
    end
  end
  # フォルダ内のメールのリスト
  class Maillist < Array
    # mail_list_get 時に使われるキー
    attr_reader :sign
    # :ok なら取得成功
    attr_reader :status
    # おそらくメールボックス内のメールの数。mail_list_get 時は無効
    attr_reader :max_size
    def initialize( status, sign, mails, max_size=nil )
      @status, @sign, @max_size = status, sign, max_size
      for mail in mails
        self << MailListItem.new( *mail )
      end
    end
  end
  # メールの詳細情報。複数のmimeパートを含むデータ
  class Mailparts
    # :ok なら取得成功
    attr_reader :status
    # Mimepart の配列
    attr_reader :parts
    # ヘッダ
    attr_reader :header
    def initialize( status , header, parts )
      @status , @header = status, header
      @parts = parts.map{|data| Mimepart.new( *data )}
    end
    def [](num)
      @parts[num]
    end
  end
  # メールのヘッダ。素の形に近い( Mimepartspec などは利用しやすいが失われている情報が多い)
  class AllMailHeaders
    # :ok なら取得成功
    attr_reader :status
    # ヘッダ。[ ["ヘッダ名","ヘッダ値"] ... ] の形式で格納されている。
    attr_reader :header
    def initialize(status, header)
      @status, @header = status, header
    end
    # メールのヘッダの形にして返す
    def to_s
      @header.map{|k,v| "#{k}: #{v}" }.join("\n")
    end
    # header に委譲
    def method_missing(sym, *args, &block)
      @header.send sym, *args, &block
    end
    # header から 対応する名前のヘッダの値を返す。複数ある場合は最初のものを返す。
    def []( name )
      @header.find{|n,a| n==name }[1]
    end
    # header から content-type の値を得る
    def content_type
      ['content-type']
    end
    # マルチパートか否か
    def multipart?
      content_type =~ /^multipart\//
    end
  end
  # メールのラベル（フォルダ）一つを表す
  class MailLabel
    # 場所。:server_folder, :user_folder, :user_flag がある
    attr_reader :place
    # システム名。place=server_folder の時は名前を表すシンボル、それ以外の時は連番
    # 名前を表すシンボルは :draft, :inbox, :sent, :trash, :upload がある
    attr_reader :index
    # 名前。メルマガフォルダの時は __MM__ が接頭辞としてつく（ 例： "__MM__雑誌" )
    attr_reader :name
    # フォルダ内のメールの数
    attr_reader :num
    # 用途不明
    attr_reader :num2
    def initialize(systemname, name, num, num2)
      @name, @num, @num2 = name, num, num2
      @place, @index = systemname
    end
  end
  # メールのラベル（フォルダ）リストを表す
  class MailLabelList
    # サーバフォルダ（既定のフォルダ）のリスト。MailLabel の配列である。
    attr_reader :server_folders
    # 個人フォルダ（およびメルマガフォルダ）のリスト。MailLabel の配列である。
    attr_reader :user_folders
    # ユーザフラグのリスト（用途不明）。MailLabel の配列である。
    attr_reader :user_flags
    # 戻りステータス :ok なら異常なし（詳細不明）
    attr_reader :status
    def initialize(status, data)
      @status = status
      @server_folders,@user_folders,@user_flags = data.map{|a| a.map{|l| MailLabel.new(*l) }}
    end
    # 名前でラベル（フォルダ）を選ぶ
    # nameがシンボルならサーバフォルダから、文字列ならユーザフォルダから選ぶ。
    # 数字ならユーザフォルダのインデックスとして選ぶ。
    def [](name)
      if name.is_a? Symbol
        return @server_folders.find{|a| a.index == name}
      elsif name.is_a? Numeric
        return @user_folders.find{|a| a.index == name}
      else
        return @user_folders.find{|a| a.name == name}
      end
      raise "invalid label key #{name}"
    end
  end
  private
  def u(str) #:nodoc:
    CGI.escape(str)
  end
end
