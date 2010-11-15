class DocomoWebMailer
  def convert_mail(header)
    text = headers.to_s
    text += "\n\n"
    if parts.parts.size == 1
      data = mail_get_attache( parts.parts[0] )
      text +="#{data}"
    else
      h = nil
      raise "unknown type header #{text}" unless headers.find{|k,v| k == "content-type" and v =~ /boundary=(.*)$/}
      boundary = $1.dup.strip.gsub(/^"(.*)"$/,'\1').gsub(/^'(.*)'$/,'\1')
      for part in parts.parts
        body = mail_get_attache( part )
        header = []
        header << "--#{boundary}"
        content_type = part.content_type
        if part.inline_head and part.inline_head.find{|n,v| n == 'content-type'}
          content_type = part.inline_head.find{|n,v| n == 'content-type'}[1]
        end
        puts "content_type=#{content_type}"
        header << "Content-Type: #{content_type}"
        is_text = content_type =~ /^text\//
        if is_text
          header << "Content-Transfer-Encoding: 8bit"
        else
          header << "Content-Transfer-Encoding: base64"
        end
        header << "Content-ID: #{part.contentid}" if part.contentid
        if part.disposition
          if part.filename
            header << "Content-Disposition: #{part.disposition}; filename=#{part.filename}"
          else
            header << "Content-Disposition: #{part.disposition}"
          end
        end
        header << ""
        if is_text
          header << body
        else
          header << Base64.encode64(body)
        end
        header << ""
        text += header.join("\n")
      end
      text +="--#{boundary}--\n"
    end
    text
  end
end
