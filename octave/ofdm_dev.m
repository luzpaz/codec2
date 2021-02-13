% ofdm_dev.m
% David Rowe Jan 2021
%
% Simulations used for development of HF data modem acquisition

ofdm_lib;
channel_lib;

% build a single modem frame preamble vector
function tx_preamble = generate_preamble(states)
  % tweak local copy of states so we can generate a 1 modem-frame packet
  states.Np = 1; states.Nbitsperpacket = states.Nbitsperframe;
  preamble_bits = rand(1,states.Nbitsperframe) > 0.5;
  tx_preamble = ofdm_mod(states, preamble_bits);
endfunction

% build a vector of Tx bursts in noise
function [rx tx_preamble burst_len padded_burst_len ct_targets states] = generate_bursts(sim_in)
  config = ofdm_init_mode(sim_in.mode);
  states = ofdm_init(config);
  ofdm_load_const;

  tx_preamble = generate_preamble(states);
  Nbursts = sim_in.Nbursts;
  tx_bits = create_ldpc_test_frame(states, coded_frame=0);
  tx_burst = [tx_preamble ofdm_mod(states, tx_bits) tx_preamble];
  burst_len = length(tx_burst);
  tx_burst = ofdm_hilbert_clipper(states, tx_burst, tx_clip_en=0);
  on_len = length(tx_burst);
  padded_burst_len = Fs+burst_len+Fs;
  
  tx = []; ct_targets = [];
  for f=1:Nbursts
    % 100ms of jitter in the burst start point
    jitter = floor(rand(1,1)*0.1*Fs);
    tx_burst_padded = [zeros(1,Fs+jitter) tx_burst zeros(1,Fs-jitter)];
    ct_targets = [ct_targets Fs+jitter];
    tx = [tx tx_burst_padded];
  end
  % adjust channel simulator SNR setpoint given (burst on length)/(sample length) ratio
  SNRdB_setpoint = sim_in.SNR3kdB + 10*log10(on_len/burst_len);
  rx = channel_simulate(Fs, SNRdB_setpoint, sim_in.foff_Hz, sim_in.channel, tx, verbose);
endfunction


% Run an acquisition test, returning vectors of estimation errors
function [delta_ct delta_foff timing_mx_log] = acquisition_test(mode="700D", Ntests=10, channel, SNR3kdB=100, foff_Hz=0, verbose_top=0)
  
  sim_in.SNR3kdB = SNR3kdB;
  sim_in.channel = channel;
  sim_in.foff_Hz = foff_Hz;  
  sim_in.mode = mode;
  sim_in.Nbursts = Ntests;
  [rx tx_preamble Nsamperburst Nsamperburstpadded ct_targets states] = generate_bursts(sim_in);
  states.verbose = bitand(verbose_top,3);
  ofdm_load_const;
  
  delta_ct = []; delta_foff = []; ct_log = []; timing_mx_log = []; 
   
  i = 1;
  states.foff_metric = 0;
  for w=1:Nsamperburstpadded:length(rx)
    [ct_est foff_est timing_mx] = est_timing_and_freq(states, rx(w:w+Nsamperburstpadded-1), tx_preamble, 
                                  tstep = 4, fmin = -50, fmax = 50, fstep = 5);
    fmin = foff_est-3; fmax = foff_est+3;
    st = w+ct_est; en = st + length(tx_preamble)-1; rx1 = rx(st:en);
    [tmp foff_est timing_mx] = est_timing_and_freq(states, rx1, tx_preamble, 
                                  tstep = 1, fmin, fmax, fstep = 1);

    % valid coarse timing could be pre-amble or post-amble
    ct_target1 = ct_targets(i);
    ct_target2 = ct_targets(i)+Nsamperburst-length(tx_preamble);
    %printf("  ct_target1: %d ct_target2: %d ct_est: %d\n", ct_target1, ct_target2, ct_est);
    ct_delta1 = ct_est-ct_target1;
    ct_delta2 = ct_est-ct_target2;
    adelta_ct = min([abs(ct_delta1) abs(ct_delta2)]);
    
    % log results
    delta_ct = [delta_ct adelta_ct];
    delta_foff = [delta_foff (foff_est-foff_Hz)];
    ct_log = [ct_log w+ct_est];
    timing_mx_log = [timing_mx_log; timing_mx];
    
    if states.verbose
      printf("i: %2d w: %8d ct_est: %6d delta_ct: %6d foff_est: %5.1f timing_mx: %3.2f\n",
              i++, w, ct_est, adelta_ct, foff_est, timing_mx);
    end

  end
  
  if bitand(verbose_top,8)
    figure(1); clf; plot(timing_mx_log,'+-'); title('mx log');
    figure(2); clf; plot(delta_ct,'+-'); title('delta ct');
    figure(3); clf; plot(delta_foff,'+-'); title('delta freq off');
    figure(5); clf; plot(real(rx)); hold on; plot(ct_log,zeros(1,length(ct_log)),'r+','markersize', 25, 'linewidth', 2); hold off;
  end
  
endfunction


#{
   Meausures aquisistion statistics for AWGN and HF channels
#}

function res = acquisition_histograms(mode="datac0", Ntests=10, SNR3kdB=100, foff=0, verbose=0)
  Fs = 8000;
  
  % allowable tolerance for acquistion

  ftol_hz = 2;              % we can sync up on this (todo: make mode selectable)
  ttol_samples = 0.006*Fs;  % CP length (todo: make mode selectable)

 % AWGN channel
 
  [dct dfoff] = acquisition_test(mode, Ntests, 'awgn', SNR3kdB, foff, verbose); 
  PtAWGN = length(find (abs(dct) < ttol_samples))/length(dct);
  PfAWGN = length(find (abs(dfoff) < ftol_hz))/length(dfoff);
  printf("SNR: %3.1f AWGN P(time) = %3.2f  P(freq) = %3.2f\n", SNR3kdB, PtAWGN, PfAWGN);

  if bitand(verbose,16)
    figure(1); clf;
    hist(dct(find (abs(dct) < ttol_samples)))
    t = sprintf("Coarse Timing Error AWGN SNR = %3.2f foff = %3.1f", SNR3kdB, foff);
    title(t)
    figure(2); clf;
    hist(dfoff(find(abs(dfoff) < 2*ftol_hz)))
    t = sprintf("Coarse Freq Error AWGN SNR = %3.2f foff = %3.1f", SNR3kdB, foff);
    title(t);
  end

  % HF channel

  [dct dfoff] = acquisition_test(mode, Ntests, 'mpp', SNR3kdB, foff, verbose); 

  PtHF = length(find (abs(dct) < ttol_samples))/length(dct);
  PfHF = length(find (abs(dfoff) < ftol_hz))/length(dfoff);
  printf("SNR: %3.1f HF   P(time) = %3.2f  P(freq) = %3.2f\n", SNR3kdB, PtHF, PfHF);

  if bitand(verbose,16)
    figure(3); clf;
    hist(dct(find (abs(dct) < ttol_samples)))
    t = sprintf("Coarse Timing Error HF SNR = %3.2f foff = %3.1f", SNR3kdB, foff);
    title(t)
    figure(4); clf;
    hist(dfoff(find(abs(dfoff) < 2*ftol_hz)))
    t = sprintf("Coarse Freq Error HF SNR = %3.2f foff = %3.1f", SNR3kdB, foff);
    title(t);
  end
  
  res = [PtAWGN PfAWGN PtHF PfHF];
endfunction


% plot some curves of Acquisition probability against EbNo and freq offset

function acquistion_curves(mode="datac1", Ntests=10)

  SNR = [ -5 0 5 15 ];
  foff = [-40 -10 0 10 -40];
  cc = ['b' 'g' 'k' 'c' 'm'];
  
  figure(1); clf; hold on; title('P(timing) AWGN'); xlabel('SNR3k dB'); legend('location', 'southeast');
  figure(2); clf; hold on; title('P(freq) AWGN'); xlabel('SNR3k dB'); legend('location', 'southeast');
  figure(3); clf; hold on; title('P(timing) HF'); xlabel('SNR3k dB'); legend('location', 'southeast');
  figure(4); clf; hold on; title('P(freq) HF'); xlabel('SNR3k dB'); legend('location', 'southeast');

  for f = 1:length(foff)
    afoff = foff(f);
    res_log = [];
    for e = 1:length(SNR)
      aSNR = SNR(e);
      res = zeros(1,4);
      res = acquisition_histograms(mode, Ntests, aSNR, afoff, verbose=1);
      res_log = [res_log; res];
    end
    figure(1); l = sprintf('%c+-;%3.1f Hz;', cc(f), afoff); plot(SNR, res_log(:,1), l);
    figure(2); l = sprintf('%c+-;%3.1f Hz;', cc(f), afoff); plot(SNR, res_log(:,3), l);
    figure(3); l = sprintf('%c+-;%3.1f Hz;', cc(f), afoff); plot(SNR, res_log(:,2), l);
    figure(4); l = sprintf('%c+-;%3.1f Hz;', cc(f), afoff); plot(SNR, res_log(:,4), l);
  end
  
  figure(1); print('-dpng', sprintf("ofdm_dev_acq_curves_time_awgn_%s.png", mode))
  figure(2); print('-dpng', sprintf("ofdm_dev_acq_curves_freq_awgn_%s.png", mode))
  figure(3); print('-dpng', sprintf("ofdm_dev_acq_curves_time_hf_%s.png", mode))
  figure(4); print('-dpng', sprintf("ofdm_dev_acq_curves_freq_hf_%s.png", mode))
endfunction


% Used to develop sync state machine - in particular a metric to show
% we are out of sync, or have sync with a bad freq offset est, or have
% lost modem signal

function sync_metrics(mode = "700D", x_axis = 'EbNo')
  Fs      = 8000;
  Ntests  = 4;
  f_offHz = [-25:25];
  EbNodB  = [-10 0 3 6 10 20];
  %f_offHz = [-5:5:5];
  %EbNodB  = [-10 0 10];
  cc = ['b' 'g' 'k' 'c' 'm' 'b'];
  pt = ['+' '+' '+' '+' '+' 'o'];
    
  mean_mx1_log = mean_dfoff_log = [];
  for f = 1:length(f_offHz)
    af_offHz = f_offHz(f);
    mean_mx1_row = mean_dfoff_row = [];
    for e = 1:length(EbNodB)
      aEbNodB = EbNodB(e);
      [dct dfoff timing_mx_log] = acquisition_test(mode, Ntests, aEbNodB, af_offHz);
      mean_mx1 = mean(timing_mx_log(:,1));
      printf("f_offHz: %5.2f EbNodB: % 6.2f mx1: %3.2f\n", af_offHz, aEbNodB, mean_mx1);
      mean_mx1_row = [mean_mx1_row mean_mx1];
      mean_dfoff_row = [mean_dfoff_row mean(dfoff)];
    end
    mean_mx1_log = [mean_mx1_log; mean_mx1_row];
    mean_dfoff_log = [mean_dfoff_log; mean_dfoff_row];
  end

  figure(1); clf; hold on; grid;
  if strcmp(x_axis,'EbNo')
    for f = 1:length(f_offHz)
      if f == 2, hold on, end;
      leg1 = sprintf("b+-;mx1 %4.1f Hz;", f_offHz(f));
      plot(EbNodB, mean_mx1_log(f,:), leg1)
    end
    hold off;
    xlabel('Eb/No (dB)');
    ylabel('Coefficient')
    title('Pilot Correlation Metric against Eb/No for different Freq Offsets');
    legend("location", "northwest"); legend("boxoff");
    axis([min(EbNodB) max(EbNodB) 0 1.2])
    print('-deps', '-color', "ofdm_dev_pilot_correlation_ebno.eps")
  end

  if strcmp(x_axis,'freq')
    % x axis is freq

    for e = length(EbNodB):-1:1
      leg1 = sprintf("%c%c-;mx1 %3.0f dB;", cc(e), pt(e), EbNodB(e));
      plot(f_offHz, mean_mx1_log(:,e), leg1)
    end
    hold off;
    xlabel('freq offset (Hz)');
    ylabel('Coefficient')
    title('Pilot Correlation Metric against Freq Offset for different Eb/No dB');
    legend("location", "northwest"); legend("boxoff");
    axis([min(f_offHz) max(f_offHz) 0 1])
    print('-deps', '-color', "ofdm_dev_pilot_correlation_freq.eps")

    mean_dfoff_log
 
    figure(2); clf;
    for e = 1:length(EbNodB)
      if e == 2, hold on, end;
      leg1 = sprintf("+-;mx1 %3.0f dB;", EbNodB(e));
      plot(f_offHz, mean_dfoff_log(:,e), leg1)
    end
    hold off;
    xlabel('freq offset (Hz)');
    ylabel('Mean Freq Est Error')
    title('Freq Est Error against Freq Offset for different Eb/No dB');
    axis([min(f_offHz) max(f_offHz) -5 5])
  end
  
endfunction


% ---------------------------------------------------------
% choose simulation to run here 
% ---------------------------------------------------------

format;
more off;
pkg load signal;
graphics_toolkit ("gnuplot");
randn('seed',1);

%acquisition_test("datac1", Ntests=10, 'mpp', SNR3kdB=0, foff_hz=-38, verbose=1+8);
%acquisition_histograms(mode="datac1", Ntests=10, SNR3kdB=0, foff=37, verbose=1+16);
%sync_metrics('freq')
acquistion_curves("datac0")
