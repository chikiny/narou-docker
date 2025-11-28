FROM ruby:3.1.6-alpine3.20

LABEL maintainer="chikiny <chikiny@gmail.com>"

# Mention branch name because forked version will be used
# Need to modify this point to corresponding branch name
ENV NAROU_VERSION=release
ENV AOZORAEPUB3_VERSION=1.1.1b31Q
ENV AOZORAEPUB3_FILE=AozoraEpub3-${AOZORAEPUB3_VERSION}

WORKDIR /temp

# set -x seems just a place folder for inserting comment before wget command
RUN set -x \
 # install AozoraEpub3
 && wget https://github.com/kyukyunyorituryo/AozoraEpub3/releases/download/v${AOZORAEPUB3_VERSION}/${AOZORAEPUB3_FILE}.zip \
 && unzip -q ${AOZORAEPUB3_FILE}.zip -d ${AOZORAEPUB3_FILE}\
 && mv ${AOZORAEPUB3_FILE} /aozoraepub3 \
 # install openjdk21
 && apk --no-cache add openjdk21 --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community \
 # install Narou.rb from github directly
 && apk --update --no-cache --virtual .build-deps add \
      build-base \
      make \
      gcc \
      git \
 && gem install specific_install \
 && gem specific_install https://github.com/chikiny/narou_rb ${NAROU_VERSION} \
 && apk del --purge .build-deps \
 # setting AozoraEpub3
 && mkdir .narousetting \
 && narou init -p /aozoraepub3 -l 1.8 \
 && rm -rf /temp

WORKDIR /novel

COPY init.sh /usr/local/bin
RUN chmod +x /usr/local/bin/init.sh

EXPOSE 33000-33001

ENTRYPOINT ["init.sh"]
CMD ["narou", "web", "-np", "33000"]
