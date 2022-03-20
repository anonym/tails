package main

import (
    // "log"
	"crypto/tls"
	"crypto/x509"
    "flag"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
    "time"
)

var verifyOpts x509.VerifyOptions
var currentTime time.Time
var onesecond_more time.Duration
var now = time.Now()
var rejectExpired = false

func init() {
    var err error
    onesecond_more, err = time.ParseDuration("1s")
    if err != nil { // but this should never happen
        panic(err)
    }
}

func verifyButAcceptExpired(rawCerts [][]byte, verifiedChains [][]*x509.Certificate) error {
    certs := make([]*x509.Certificate, len(rawCerts))
	for i, asn1Data := range rawCerts {
		cert, _ := x509.ParseCertificate(asn1Data)
        certs[i] = cert
	}
    for _, cert := range certs[1:] {
        verifyOpts.Intermediates.AddCert(cert)
    }

	if err := certs[0].VerifyHostname(verifyOpts.DNSName); err != nil {
        return err
    }

    // log.Println("shall we reject?", rejectExpired, "is future?", certs[0].NotBefore.After(currentTime))
    if !rejectExpired || certs[0].NotBefore.After(currentTime) {
        verifyOpts.CurrentTime = certs[0].NotBefore.Add(onesecond_more)
    } else {
        verifyOpts.CurrentTime = currentTime
    }

	if _, err := certs[0].Verify(verifyOpts); err != nil {
        return err
	}

	return nil
}

func main() {
    var err error
    // currentTimeS := flag.String("current-time", "", "simulate a different current-time")
    flag.BoolVar(&rejectExpired, "reject-expired", false, "If set, only future certificates are accepted")
	output_headers := flag.String("output", "", "Write headers to FILE")
    flag.Parse()
    currentTimeS := os.Getenv("FAKETIME")
    if len(currentTimeS) > 0 {
        currentTime, err = time.Parse("2006-01-02", currentTimeS)
        if err != nil {
            fmt.Fprintln(os.Stderr, "Invalid format for current-time:", err.Error())
            os.Exit(2)
        }
    } else {
        currentTime = time.Now()
    }


	urlString := flag.Args()[0]
	urlRequest, err := url.Parse(urlString)
	if err != nil {
		fmt.Fprintln(os.Stderr, "invlid url")
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
    hostname := urlRequest.Hostname()

    config := tls.Config{VerifyPeerCertificate: verifyButAcceptExpired, InsecureSkipVerify: true}
	transCfg := &http.Transport{
		TLSClientConfig: &config,
	}
    verifyOpts = x509.VerifyOptions{
        Roots:         config.RootCAs,
        DNSName:       hostname,
        Intermediates: x509.NewCertPool(),
    }
	client := &http.Client{Transport: transCfg}

	response, err := client.Head(urlString)

	if err != nil {
		fmt.Fprintln(os.Stderr, "Error in Get")
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	if *output_headers != "" {

		// don't output headers we don't care about
		exclude_headers := make(map[string]bool)
		for key, _ := range(response.Header) {
			if strings.ToLower(key) != "date" {
				exclude_headers[key] = true
			}
		}

		buf, err := os.OpenFile(*output_headers, os.O_WRONLY | os.O_CREATE, 0600)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}

		err = response.Header.WriteSubset(buf, exclude_headers)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		os.Exit(0)
	} else {
		fmt.Println(response.Header.Get("date"))
	}

    os.Exit(0)
}
