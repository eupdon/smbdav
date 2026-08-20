# smbdav

<div class="snippet-clipboard-content position-relative" data-snippet-clipboard-copy-content="services:
  smbdav:
    container_name: smbdav
    ports:
      - 80:80
      - 445:445
    environment:
      - USER1=kim;folder1,folder2
      - PASS1=kim123
      - USER2=lee;folder2,folder3
      - PASS2=lee456
    volumes:
      - ./storage:/srv/share
    restart: unless-stopped
    image: ghcr.io/eupdon/smbdav:sha-cd64314
networks: {}
"><pre><code>services:
  smbdav:
    container_name: smbdav
    ports:
      - 80:80
      - 445:445
    environment:
      - USER1=kim;folder1,folder2
      - PASS1=kim123
      - USER2=lee;folder2,folder3
      - PASS2=lee456
    volumes:
      - ./storage:/srv/share
    restart: unless-stopped
    image: ghcr.io/eupdon/smbdav:sha-cd64314
networks: {}
</code></pre></div>
